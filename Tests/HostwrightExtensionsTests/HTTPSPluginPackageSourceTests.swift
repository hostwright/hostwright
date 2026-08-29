import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightExtensions
import HostwrightRegistry
import XCTest

final class HTTPSPluginPackageSourceTests: XCTestCase {
    func testMaterializesOnlyConfiguredManifestAndDeclaredFilesIntoPrivateDirectory() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PluginSource(
            kind: .httpsRegistry,
            locator: "https://plugins.example.test/packages/example/"
        )
        let files = [
            "Resources/first.json": Data("first".utf8),
            "Resources/second.json": Data("second".utf8),
            "plugin.wasm": Data("wasm".utf8),
        ]
        let manifestData = try manifestData(source: source, files: files)
        let transport = ScriptedRegistryTransport(responses: [
            "https://plugins.example.test/packages/example/manifest.json": response(manifestData),
            "https://plugins.example.test/packages/example/Resources/first.json": response(files["Resources/first.json"]!),
            "https://plugins.example.test/packages/example/Resources/second.json": response(files["Resources/second.json"]!),
            "https://plugins.example.test/packages/example/plugin.wasm": response(files["plugin.wasm"]!),
        ])
        let materializer = HTTPSPluginPackageSourceMaterializer(
            transport: transport,
            temporaryRootURL: root
        )

        let package = try materializer.materialize(source: source)

        XCTAssertEqual(
            transport.requests.map(\.url.absoluteString),
            [
                "https://plugins.example.test/packages/example/manifest.json",
                "https://plugins.example.test/packages/example/Resources/first.json",
                "https://plugins.example.test/packages/example/Resources/second.json",
                "https://plugins.example.test/packages/example/plugin.wasm",
            ]
        )
        XCTAssertEqual(transport.requests.map(\.headers), [
            ["Accept": "application/json"],
            ["Accept": "application/octet-stream"],
            ["Accept": "application/octet-stream"],
            ["Accept": "application/octet-stream"],
        ])
        XCTAssertEqual(permissions(package.directoryURL.path), 0o700)
        XCTAssertEqual(
            try Data(contentsOf: package.directoryURL.appendingPathComponent("plugin.wasm")),
            files["plugin.wasm"]
        )
        XCTAssertEqual(
            permissions(package.directoryURL.appendingPathComponent("Resources/first.json").path),
            0o600
        )
        XCTAssertEqual(
            permissions(package.directoryURL.appendingPathComponent("Resources/second.json").path),
            0o600
        )

        try package.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directoryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRefusesImplicitNonHTTPSOrQueryConfiguredSourcesBeforeNetworkAccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedRegistryTransport(responses: [:])
        let materializer = HTTPSPluginPackageSourceMaterializer(
            transport: transport,
            temporaryRootURL: root
        )

        for source in [
            PluginSource(kind: .localDirectory, locator: "/private/plugin"),
            PluginSource(kind: .httpsRegistry, locator: "https://plugins.example.test/package?token=secret"),
        ] {
            XCTAssertThrowsError(try materializer.materialize(source: source)) { error in
                let diagnostic = error as? HostwrightDiagnostic
                XCTAssertNotNil(diagnostic)
                XCTAssertFalse(diagnostic?.message.contains("secret") == true)
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testCancellationAndTransportFailureAreSanitizedAndLeaveNoMaterialization() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PluginSource(
            kind: .httpsRegistry,
            locator: "https://plugins.example.test/packages/example/"
        )
        let cancelled = RegistryTransportCancellation()
        cancelled.cancel()
        let transport = ScriptedRegistryTransport(responses: [:])
        let materializer = HTTPSPluginPackageSourceMaterializer(
            transport: transport,
            temporaryRootURL: root
        )

        XCTAssertThrowsError(try materializer.materialize(source: source, cancellation: cancelled)) { error in
            let diagnostic = error as? HostwrightDiagnostic
            XCTAssertEqual(diagnostic?.code, .extensionExecutionFailed)
            XCTAssertTrue(diagnostic?.message.contains("cancelled") == true)
        }
        XCTAssertTrue(transport.requests.isEmpty)

        let secret = "token=must-not-leak"
        let failingTransport = ScriptedRegistryTransport(responses: [
            "https://plugins.example.test/packages/example/manifest.json": RegistryTransportResponse(
                statusCode: 500,
                headers: [:],
                body: Data(secret.utf8)
            ),
        ])
        let failingMaterializer = HTTPSPluginPackageSourceMaterializer(
            transport: failingTransport,
            temporaryRootURL: root
        )
        XCTAssertThrowsError(try failingMaterializer.materialize(source: source)) { error in
            let diagnostic = error as? HostwrightDiagnostic
            XCTAssertEqual(diagnostic?.code, .extensionExecutionFailed)
            XCTAssertFalse(diagnostic?.message.contains(secret) == true)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
        XCTAssertEqual(try children(of: root), [])
    }

    func testCleanupRefusesUnownedArtifactsUntilExactTreeIsRestored() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = PluginSource(
            kind: .httpsRegistry,
            locator: "https://plugins.example.test/packages/example/"
        )
        let files = ["plugin.wasm": Data("wasm".utf8)]
        let manifest = try manifestData(source: source, files: files)
        let transport = ScriptedRegistryTransport(responses: [
            "https://plugins.example.test/packages/example/manifest.json": response(manifest),
            "https://plugins.example.test/packages/example/plugin.wasm": response(files["plugin.wasm"]!),
        ])
        let package = try HTTPSPluginPackageSourceMaterializer(
            transport: transport,
            temporaryRootURL: root
        ).materialize(source: source)
        let rogue = package.directoryURL.appendingPathComponent("rogue.txt")
        try Data("rogue".utf8).write(to: rogue)

        XCTAssertThrowsError(try package.cleanup()) { error in
            let diagnostic = error as? HostwrightDiagnostic
            XCTAssertEqual(diagnostic?.code, .extensionExecutionFailed)
            XCTAssertTrue(diagnostic?.message.contains("unowned artifacts") == true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.directoryURL.path))

        try FileManager.default.removeItem(at: rogue)
        try package.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.directoryURL.path))
    }

    private func manifestData(source: PluginSource, files: [String: Data]) throws -> Data {
        let digests = files.keys.sorted().map { path in
            PluginContentDigest(path: path, digest: digest(files[path]!))
        }
        let manifest = PluginPackageManifest(
            identifier: "dev.hostwright.source-test",
            packageVersion: "1.0.0",
            hostwrightCompatibility: "0.0.2",
            providerKind: .wasi,
            entrypoint: "plugin.wasm",
            grants: [PluginGrant(capability: .diagnostics, scope: "read")],
            artifactDigest: digest(files["plugin.wasm"]!),
            contentDigests: digests,
            provenance: PluginProvenance(
                checksum: digest(Data("package".utf8)),
                signature: "test-signature",
                signerIdentifier: "test-signer",
                source: source
            ),
            cmsSignature: "test-signature",
            signerIdentifier: "test-signer"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    private func response(_ data: Data) -> RegistryTransportResponse {
        RegistryTransportResponse(statusCode: 200, headers: [:], body: data)
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-https-package-source-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func permissions(_ path: String) -> mode_t {
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        return metadata.st_mode & mode_t(0o777)
    }

    private func children(of root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }
}

private final class ScriptedRegistryTransport: RegistrySynchronousHTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: RegistryTransportResponse]
    private var storedRequests: [RegistryTransportRequest] = []

    init(responses: [String: RegistryTransportResponse]) {
        self.responses = responses
    }

    var requests: [RegistryTransportRequest] {
        lock.withLock { storedRequests }
    }

    func send(
        _ request: RegistryTransportRequest,
        cancellation: RegistryTransportCancellation
    ) throws -> RegistryTransportResponse {
        if cancellation.isCancelled {
            throw RegistryTransportError.cancelled
        }
        return try lock.withLock {
            storedRequests.append(request)
            guard let response = responses[request.url.absoluteString] else {
                throw RegistryTransportError.transportFailed
            }
            return response
        }
    }
}
