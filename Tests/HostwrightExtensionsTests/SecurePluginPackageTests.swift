import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightExtensions
import XCTest

final class SecurePluginPackageTests: XCTestCase {
    func testCompatibilityRangeIsBoundedAndUsesANDSemantics() throws {
        let range = try PluginCompatibilityRange(">=0.0.2,<0.1.0")
        let spaced = try PluginCompatibilityRange(">=0.0.2 <0.1.0")
        let mixed = try PluginCompatibilityRange(">=0.0.2, <0.1.0")
        XCTAssertTrue(try range.contains("0.0.2"))
        XCTAssertTrue(try range.contains("0.0.9-dev.1"))
        XCTAssertFalse(try range.contains("0.1.0"))
        XCTAssertTrue(try spaced.contains("0.0.2"))
        XCTAssertTrue(try mixed.contains("0.0.9"))
        XCTAssertFalse(try spaced.contains("0.1.0"))
        XCTAssertThrowsError(try PluginCompatibilityRange(">=0.0"))
        XCTAssertThrowsError(try PluginCompatibilityRange(">=0.0.2 || <1.0.0"))
        XCTAssertThrowsError(try PluginCompatibilityRange(">=0.0.2 | <1.0.0"))
        XCTAssertThrowsError(try PluginCompatibilityRange("1.0.0,2.0.0,3.0.0,4.0.0,5.0.0"))
    }

    func testSemanticVersionPrereleaseOrderingMatchesSemVer() throws {
        let alpha = try PluginCompatibilityRange.Version("1.0.0-alpha")
        let alphaOne = try PluginCompatibilityRange.Version("1.0.0-alpha.1")
        let beta = try PluginCompatibilityRange.Version("1.0.0-beta")
        let release = try PluginCompatibilityRange.Version("1.0.0")
        let alphaBuild = try PluginCompatibilityRange.Version("1.0.0-alpha+build.01")
        let releaseBuild = try PluginCompatibilityRange.Version("1.0.0+build.01")
        XCTAssertLessThan(alpha, alphaOne)
        XCTAssertLessThan(alphaOne, beta)
        XCTAssertLessThan(beta, release)
        XCTAssertLessThan(alphaBuild, releaseBuild)
        XCTAssertEqual(releaseBuild, release)
        XCTAssertThrowsError(try PluginCompatibilityRange.Version("01.0.0"))
        XCTAssertThrowsError(try PluginCompatibilityRange.Version("1.0.0-01"))
        XCTAssertThrowsError(try PluginCompatibilityRange.Version("1.0.0-alpha..1"))
        XCTAssertThrowsError(try PluginCompatibilityRange.Version("1.0.0-alpha.01"))
    }

    func testVerifierRejectsNonSemVerManifestPackageVersionsBeforeAcceptance() throws {
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")

        for version in ["01.0.0", "1.0.0-alpha..1", "1.0.0-alpha.01"] {
            let fixture = try makePackageFixture(signer: signer) { fixture in
                let manifestText = String(decoding: fixture.manifestData, as: UTF8.self)
                let replacement = manifestText.replacingOccurrences(
                    of: #""packageVersion":"1.0.0""#,
                    with: #""packageVersion":"\#(version)""#
                )
                XCTAssertNotEqual(manifestText, replacement)
                try XCTUnwrap(replacement.data(using: .utf8)).write(
                    to: fixture.root.appendingPathComponent(PluginPackageVerifier.manifestFileName)
                )
            }
            let verifier = try PluginPackageVerifier(
                trustedSignerCertificates: [fixture.manifest.signerIdentifier: signer.certificateDER]
            )
            assertDiagnostic(
                tryVerify: {
                    try verifier.verifyMaterializedPackage(
                        at: fixture.root,
                        expectedSource: fixture.expectedSource
                    )
                },
                code: .extensionInvalid
            ) {
                XCTAssertTrue($0.message.contains("package version is not valid SemVer"))
            }
        }
    }

    func testManifestSigningPayloadAndPackageDigestAreDeterministic() throws {
        let source = PluginSource(kind: .localDirectory, locator: "/tmp/plugin-source")
        let contentA = PluginContentDigest(
            path: "Resources/config.json",
            digest: digest(Data("config".utf8))
        )
        let contentB = PluginContentDigest(
            path: "plugin.wasm",
            digest: digest(Data("wasm".utf8))
        )
        let provenance = PluginProvenance(
            checksum: try PluginPackageVerifier.packageDigest(contentDigests: [contentA, contentB]),
            signature: Data("provenance".utf8).base64EncodedString(),
            signerIdentifier: "dev.hostwright.signer",
            source: source
        )
        let manifestA = PluginPackageManifest(
            identifier: "dev.hostwright.plugin",
            packageVersion: "1.0.0",
            hostwrightCompatibility: ">=1.0.0",
            providerKind: .wasi,
            entrypoint: "plugin.wasm",
            grants: [
                PluginGrant(capability: .diagnostics, scope: "read"),
                PluginGrant(capability: .observation, scope: "inspect")
            ],
            artifactDigest: contentB.digest,
            contentDigests: [contentA, contentB],
            provenance: provenance,
            cmsSignature: Data("manifest-a".utf8).base64EncodedString(),
            signerIdentifier: "dev.hostwright.signer"
        )
        let manifestB = PluginPackageManifest(
            identifier: manifestA.identifier,
            packageVersion: manifestA.packageVersion,
            hostwrightCompatibility: manifestA.hostwrightCompatibility,
            providerKind: manifestA.providerKind,
            entrypoint: manifestA.entrypoint,
            grants: manifestA.grants,
            artifactDigest: manifestA.artifactDigest,
            contentDigests: manifestA.contentDigests,
            provenance: manifestA.provenance,
            cmsSignature: Data("manifest-b".utf8).base64EncodedString(),
            signerIdentifier: manifestA.signerIdentifier
        )

        XCTAssertEqual(
            try PluginPackageVerifier.manifestSigningPayload(manifestA),
            try PluginPackageVerifier.manifestSigningPayload(manifestB)
        )
        XCTAssertEqual(
            try PluginPackageVerifier.packageDigest(contentDigests: [contentA, contentB]),
            try PluginPackageVerifier.packageDigest(contentDigests: [contentB, contentA])
        )
    }

    func testVerifierAcceptsValidCMSSignedPackage() throws {
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")
        let fixture = try makePackageFixture(signer: signer)
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: [fixture.manifest.signerIdentifier: signer.certificateDER]
        )

        let verified = try verifier.verifyMaterializedPackage(
            at: fixture.root,
            expectedSource: fixture.expectedSource
        )

        XCTAssertEqual(verified.manifest, fixture.manifest)
        XCTAssertEqual(verified.manifestData, fixture.manifestData)
        XCTAssertEqual(verified.packageDigest, fixture.packageDigest)
        XCTAssertEqual(verified.sourceDirectoryURL, fixture.root)
    }

    func testVerifierRejectsNonCanonicalManifestAndUndeclaredDependency() throws {
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")

        let nonCanonical = try makePackageFixture(signer: signer) { fixture in
            let text = String(decoding: fixture.manifestData, as: UTF8.self) + "\n"
            let data = try XCTUnwrap(text.data(using: .utf8))
            try data.write(
                to: fixture.root.appendingPathComponent(PluginPackageVerifier.manifestFileName)
            )
        }
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: [nonCanonical.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try verifier.verifyMaterializedPackage(
                    at: nonCanonical.root,
                    expectedSource: nonCanonical.expectedSource
                )
            },
            code: .extensionInvalid
        ) {
            XCTAssertTrue($0.message.contains("exact canonical JSON"))
        }

        let undeclared = try makePackageFixture(signer: signer) { fixture in
            try self.writeFile(
                root: fixture.root,
                relativePath: "Extras/rogue.txt",
                data: Data("rogue".utf8)
            )
        }
        let secondVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [undeclared.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try secondVerifier.verifyMaterializedPackage(
                    at: undeclared.root,
                    expectedSource: undeclared.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("missing or undeclared dependency files"))
        }
    }

    func testVerifierRejectsPathTraversalSymlinkAndSpecialFiles() throws {
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")

        let traversal = try makePackageFixture(signer: signer) { fixture in
            let traversalManifest = PluginPackageManifest(
                abiVersion: fixture.manifest.abiVersion,
                identifier: fixture.manifest.identifier,
                packageVersion: fixture.manifest.packageVersion,
                hostwrightCompatibility: fixture.manifest.hostwrightCompatibility,
                providerKind: fixture.manifest.providerKind,
                entrypoint: fixture.manifest.entrypoint,
                grants: fixture.manifest.grants,
                artifactDigest: fixture.manifest.artifactDigest,
                contentDigests: [
                    PluginContentDigest(path: "../escape.txt", digest: digest(Data("escape".utf8))),
                    PluginContentDigest(path: fixture.manifest.entrypoint, digest: fixture.manifest.artifactDigest)
                ],
                provenance: fixture.manifest.provenance,
                cmsSignature: fixture.manifest.cmsSignature,
                signerIdentifier: fixture.manifest.signerIdentifier
            )
            try self.rewriteManifest(at: fixture.root, manifest: traversalManifest)
        }
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: [traversal.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try verifier.verifyMaterializedPackage(
                    at: traversal.root,
                    expectedSource: traversal.expectedSource
                )
            },
            code: .extensionInvalid
        ) {
            XCTAssertTrue($0.message.contains("Plugin ABI v1"))
        }

        let symlinked = try makePackageFixture(signer: signer) { fixture in
            let target = fixture.root.appendingPathComponent("target.txt")
            try Data("linked".utf8).write(to: target)
            let link = fixture.root.appendingPathComponent("linked.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        }
        let symlinkVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [symlinked.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try symlinkVerifier.verifyMaterializedPackage(
                    at: symlinked.root,
                    expectedSource: symlinked.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("symlinks or special files"))
        }

        let special = try makePackageFixture(signer: signer) { fixture in
            let fifo = fixture.root.appendingPathComponent("named.pipe")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        }
        let specialVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [special.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try specialVerifier.verifyMaterializedPackage(
                    at: special.root,
                    expectedSource: special.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("symlinks or special files"))
        }
    }

    func testVerifierRejectsArtifactContentAndChecksumMismatch() throws {
        let signer = try TestCMSSigner(commonName: "Hostwright Plugin Test")

        let artifactMismatch = try makePackageFixture(signer: signer) { fixture in
            var manifest = fixture.manifest
            manifest = PluginPackageManifest(
                abiVersion: manifest.abiVersion,
                identifier: manifest.identifier,
                packageVersion: manifest.packageVersion,
                hostwrightCompatibility: manifest.hostwrightCompatibility,
                providerKind: manifest.providerKind,
                entrypoint: manifest.entrypoint,
                grants: manifest.grants,
                artifactDigest: digest(Data("wrong-artifact".utf8)),
                contentDigests: manifest.contentDigests,
                provenance: manifest.provenance,
                cmsSignature: manifest.cmsSignature,
                signerIdentifier: manifest.signerIdentifier
            )
            try self.rewriteManifest(at: fixture.root, manifest: manifest)
        }
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: [artifactMismatch.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try verifier.verifyMaterializedPackage(
                    at: artifactMismatch.root,
                    expectedSource: artifactMismatch.expectedSource
                )
            },
            code: .extensionInvalid
        ) {
            XCTAssertTrue($0.message.contains("exact declared artifact digest"))
        }

        let contentMismatch = try makePackageFixture(signer: signer) { fixture in
            try self.writeFile(
                root: fixture.root,
                relativePath: "plugin.wasm",
                data: Data("tampered-wasm".utf8)
            )
        }
        let secondVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [contentMismatch.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try secondVerifier.verifyMaterializedPackage(
                    at: contentMismatch.root,
                    expectedSource: contentMismatch.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("content exceeds its bound or digest"))
        }

        let checksumMismatch = try makePackageFixture(signer: signer) { fixture in
            let brokenProvenance = PluginProvenance(
                checksum: digest(Data("wrong-package".utf8)),
                signature: fixture.manifest.provenance.signature,
                signerIdentifier: fixture.manifest.provenance.signerIdentifier,
                source: fixture.manifest.provenance.source
            )
            let manifest = PluginPackageManifest(
                abiVersion: fixture.manifest.abiVersion,
                identifier: fixture.manifest.identifier,
                packageVersion: fixture.manifest.packageVersion,
                hostwrightCompatibility: fixture.manifest.hostwrightCompatibility,
                providerKind: fixture.manifest.providerKind,
                entrypoint: fixture.manifest.entrypoint,
                grants: fixture.manifest.grants,
                artifactDigest: fixture.manifest.artifactDigest,
                contentDigests: fixture.manifest.contentDigests,
                provenance: brokenProvenance,
                cmsSignature: fixture.manifest.cmsSignature,
                signerIdentifier: fixture.manifest.signerIdentifier
            )
            try self.rewriteManifest(at: fixture.root, manifest: manifest)
        }
        let thirdVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [checksumMismatch.manifest.signerIdentifier: signer.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try thirdVerifier.verifyMaterializedPackage(
                    at: checksumMismatch.root,
                    expectedSource: checksumMismatch.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("checksum does not match"))
        }
    }

    func testVerifierRejectsWrongSignerUnsafePermissionsAndOversizedWASIEntrypoint() throws {
        let trustedSigner = try TestCMSSigner(commonName: "Trusted Plugin Signer")
        let untrustedSigner = try TestCMSSigner(commonName: "Untrusted Plugin Signer")

        let wrongSigner = try makePackageFixture(signer: trustedSigner)
        let verifier = try PluginPackageVerifier(
            trustedSignerCertificates: ["dev.hostwright.other-signer": untrustedSigner.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try verifier.verifyMaterializedPackage(
                    at: wrongSigner.root,
                    expectedSource: wrongSigner.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("signer is not trusted"))
        }

        let untrustedCMS = try makePackageFixture(
            signer: trustedSigner,
            manifestSigner: untrustedSigner
        )
        let secondVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [untrustedCMS.manifest.signerIdentifier: trustedSigner.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try secondVerifier.verifyMaterializedPackage(
                    at: untrustedCMS.root,
                    expectedSource: untrustedCMS.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("CMS verification failed"))
        }

        let unsafePermissions = try makePackageFixture(signer: trustedSigner) { fixture in
            XCTAssertEqual(chmod(fixture.root.path, 0o722), 0)
        }
        let thirdVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [unsafePermissions.manifest.signerIdentifier: trustedSigner.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try thirdVerifier.verifyMaterializedPackage(
                    at: unsafePermissions.root,
                    expectedSource: unsafePermissions.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("caller-owned and private"))
        }

        let oversized = try makePackageFixture(
            signer: trustedSigner,
            contentFiles: ["plugin.wasm": Data(repeating: 0x41, count: PluginPackageVerifier.maximumWASIModuleBytes + 1)],
            entrypoint: "plugin.wasm"
        )
        let fourthVerifier = try PluginPackageVerifier(
            trustedSignerCertificates: [oversized.manifest.signerIdentifier: trustedSigner.certificateDER]
        )
        assertDiagnostic(
            tryVerify: {
                try fourthVerifier.verifyMaterializedPackage(
                    at: oversized.root,
                    expectedSource: oversized.expectedSource
                )
            },
            code: .extensionBlocked
        ) {
            XCTAssertTrue($0.message.contains("unsafe identity, mode, type, or size"))
        }
    }

    private func makePackageFixture(
        signer: TestCMSSigner,
        manifestSigner: TestCMSSigner? = nil,
        contentFiles: [String: Data] = [
            "Resources/config.json": Data(#"{"mode":"test"}"#.utf8),
            "plugin.wasm": Data("valid-wasm-module".utf8)
        ],
        entrypoint: String = "plugin.wasm",
        mutate: ((PackageFixture) throws -> Void)? = nil
    ) throws -> PackageFixture {
        let root = temporaryDirectory()
        let source = PluginSource(kind: .localDirectory, locator: root.path)
        let sortedContent = try contentFiles.map { path, data in
            try writeFile(root: root, relativePath: path, data: data)
            return PluginContentDigest(path: path, digest: digest(data))
        }.sorted {
            ($0.path, $0.digest) < ($1.path, $1.digest)
        }
        let packageDigest = try PluginPackageVerifier.packageDigest(contentDigests: sortedContent)
        let signerIdentifier = "dev.hostwright.plugin-signer"
        let provenanceSigner = manifestSigner ?? signer
        let provenance = PluginProvenance(
            checksum: packageDigest,
            signature: try provenanceSigner.sign(Data(packageDigest.utf8)).base64EncodedString(),
            signerIdentifier: signerIdentifier,
            source: source
        )
        let placeholderCMS = Data("placeholder".utf8).base64EncodedString()
        let unsignedManifest = PluginPackageManifest(
            identifier: "dev.hostwright.plugin",
            packageVersion: "1.0.0",
            hostwrightCompatibility: ">=1.0.0",
            providerKind: .wasi,
            entrypoint: entrypoint,
            grants: [PluginGrant(capability: .diagnostics, scope: "read")],
            artifactDigest: try XCTUnwrap(sortedContent.first(where: { $0.path == entrypoint })?.digest),
            contentDigests: sortedContent,
            provenance: provenance,
            cmsSignature: placeholderCMS,
            signerIdentifier: signerIdentifier
        )
        let manifestCMS = try (manifestSigner ?? signer).sign(
            PluginPackageVerifier.manifestSigningPayload(unsignedManifest)
        )
        let manifest = PluginPackageManifest(
            abiVersion: unsignedManifest.abiVersion,
            identifier: unsignedManifest.identifier,
            packageVersion: unsignedManifest.packageVersion,
            hostwrightCompatibility: unsignedManifest.hostwrightCompatibility,
            providerKind: unsignedManifest.providerKind,
            entrypoint: unsignedManifest.entrypoint,
            grants: unsignedManifest.grants,
            artifactDigest: unsignedManifest.artifactDigest,
            contentDigests: unsignedManifest.contentDigests,
            provenance: unsignedManifest.provenance,
            cmsSignature: manifestCMS.base64EncodedString(),
            signerIdentifier: unsignedManifest.signerIdentifier
        )
        let manifestData = try rewriteManifest(at: root, manifest: manifest)
        let fixture = PackageFixture(
            root: root,
            expectedSource: source,
            manifest: manifest,
            manifestData: manifestData,
            packageDigest: packageDigest
        )
        try mutate?(fixture)
        return fixture
    }

    @discardableResult
    private func rewriteManifest(at root: URL, manifest: PluginPackageManifest) throws -> Data {
        let data = try ControlPlaneCanonicalJSON.encode(manifest)
        try data.write(to: root.appendingPathComponent(PluginPackageVerifier.manifestFileName))
        return data
    }

    private func writeFile(root: URL, relativePath: String, data: Data) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL)
        XCTAssertEqual(chmod(fileURL.path, 0o600), 0)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-plugin-package-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertEqual(chmod(url.path, 0o700), 0)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        guard let resolved = realpath(url.path, nil) else {
            XCTFail("Could not resolve the plugin fixture root")
            return url
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private func assertDiagnostic<T>(
        tryVerify: () throws -> T,
        code: HostwrightErrorCode,
        inspect: (HostwrightDiagnostic) -> Void = { _ in }
    ) {
        XCTAssertThrowsError(try tryVerify()) { error in
            guard let diagnostic = error as? HostwrightDiagnostic else {
                return XCTFail("Expected HostwrightDiagnostic, got \(error)")
            }
            XCTAssertEqual(diagnostic.code.rawValue, code.rawValue)
            inspect(diagnostic)
        }
    }
}

private struct PackageFixture {
    let root: URL
    let expectedSource: PluginSource
    let manifest: PluginPackageManifest
    let manifestData: Data
    let packageDigest: String
}

private final class TestCMSSigner {
    let certificateDER: Data
    private let root: URL
    private let keyURL: URL
    private let certificateURL: URL

    init(commonName: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-plugin-cms-\(UUID().uuidString)", isDirectory: true)
        keyURL = root.appendingPathComponent("key.pem")
        certificateURL = root.appendingPathComponent("certificate.pem")
        let certificateDERURL = root.appendingPathComponent("certificate.der")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
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
        let contentURL = root.appendingPathComponent("content-\(UUID().uuidString).bin")
        let signatureURL = root.appendingPathComponent("signature-\(UUID().uuidString).der")
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
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TestCMSError.opensslFailed
        }
    }
}

private enum TestCMSError: Error {
    case opensslFailed
}

private func digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
