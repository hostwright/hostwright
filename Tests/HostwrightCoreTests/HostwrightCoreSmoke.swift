import Foundation
import XCTest
@testable import HostwrightCore

final class HostwrightCoreTests: XCTestCase {
    func testHostwrightIdentityConstants() {
        XCTAssertEqual(HostwrightIdentity.projectName, "Hostwright")
        XCTAssertEqual(HostwrightIdentity.cliName, "hostwright")
        XCTAssertEqual(HostwrightIdentity.daemonName, "hostwrightd")
        XCTAssertEqual(HostwrightIdentity.manifestFileName, "hostwright.yaml")
        XCTAssertEqual(HostwrightIdentity.domain, "hostwright.dev")
        XCTAssertEqual(HostwrightIdentity.version, "0.1.0-alpha.1")
    }

    func testCompatibilityGateRejectsUnsupportedPlatform() {
        let diagnostics = CompatibilityGate.evaluate(
            PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(diagnostics.map(\.code), [.unsupportedArchitecture, .unsupportedMacOSVersion])
    }

    func testReleaseDocsDescribeAlphaSourceOnlyTruth() throws {
        let root = try packageRoot()
        let releaseProcess = try read("docs/release/RELEASE_PROCESS.md", root: root)
        let releaseNotes = try read("docs/release/v0.1.0-alpha.1-notes.md", root: root)
        let install = try read("docs/reference/install.md", root: root)
        let security = try read("docs/reference/security-safety.md", root: root)
        let limitations = try read("docs/reference/limitations.md", root: root)
        let publicDocs = [releaseProcess, releaseNotes, install, security, limitations].joined(separator: "\n")

        XCTAssertTrue(releaseProcess.contains("v0.1.0-alpha.1"))
        XCTAssertTrue(releaseProcess.contains("GitHub Releases are created only for `v*` tags."))
        XCTAssertTrue(releaseProcess.contains("Artifact policy: source-only"))
        XCTAssertTrue(releaseNotes.localizedCaseInsensitiveContains("not production ready"))
        XCTAssertTrue(install.localizedCaseInsensitiveContains("source-only alpha"))
        XCTAssertTrue(security.localizedCaseInsensitiveContains("not production ready"))

        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("brew install"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("installer package is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("binary downloads are provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("signed binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("notarized binary is provided"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("is production ready"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Kubernetes"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports CRI"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Docker API"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports Docker Compose"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports cloud"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports GPU"))
        XCTAssertFalse(publicDocs.localizedCaseInsensitiveContains("supports ANE"))
    }

    private func read(_ relativePath: String, root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("README.md").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                throw NSError(domain: "HostwrightCoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate package root."])
            }
            url = parent
        }
    }
}
