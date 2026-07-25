import Darwin
import Foundation
@testable import HostwrightRegistry
import XCTest

final class RegistryCredentialFileTests: XCTestCase {
    func testDefaultLoaderReadsExactPrivateDockerAndOCIAuthFiles() throws {
        let root = try makeSecureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let docker = root.appendingPathComponent("docker", isDirectory: true)
        let oci = root.appendingPathComponent("containers", isDirectory: true)
        try createSecureDirectory(docker)
        try createSecureDirectory(oci)
        let dockerFile = docker.appendingPathComponent("config.json")
        let ociFile = oci.appendingPathComponent("auth.json")
        try writePrivate(Data(#"{"auths":{}}"#.utf8), to: dockerFile)
        try writePrivate(Data(#"{"auths":{}}"#.utf8), to: ociFile)

        let documents = try RegistryCredentialDocumentLoader.loadDefault(
            environment: [
                "DOCKER_CONFIG": docker.path,
                "REGISTRY_AUTH_FILE": ociFile.path
            ],
            homeDirectory: root.path
        )

        XCTAssertEqual(
            documents.map(\.source),
            [.dockerAuthFile, .ociAuthFile]
        )
        XCTAssertEqual(
            documents.map(\.data),
            [
                Data(#"{"auths":{}}"#.utf8),
                Data(#"{"auths":{}}"#.utf8)
            ]
        )
    }

    func testLoaderRejectsAccessGrantingModesAndSymlinks() throws {
        let root = try makeSecureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let docker = root.appendingPathComponent("docker", isDirectory: true)
        try createSecureDirectory(docker)
        let target = docker.appendingPathComponent("target.json")
        let configured = docker.appendingPathComponent("config.json")
        try writePrivate(Data(#"{"auths":{}}"#.utf8), to: target)
        XCTAssertEqual(symlink(target.path, configured.path), 0)

        XCTAssertThrowsError(
            try RegistryCredentialDocumentLoader.loadDefault(
                environment: ["DOCKER_CONFIG": docker.path],
                homeDirectory: root.path
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryCredentialLookupError,
                .invalidConfiguration
            )
        }

        XCTAssertEqual(unlink(configured.path), 0)
        try writePrivate(Data(#"{"auths":{}}"#.utf8), to: configured)
        XCTAssertEqual(chmod(configured.path, 0o644), 0)
        XCTAssertThrowsError(
            try RegistryCredentialDocumentLoader.loadDefault(
                environment: ["DOCKER_CONFIG": docker.path],
                homeDirectory: root.path
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryCredentialLookupError,
                .invalidConfiguration
            )
        }
    }

    func testLoaderRejectsRelativeEnvironmentOverridesBeforeFileAccess() throws {
        XCTAssertThrowsError(
            try RegistryCredentialDocumentLoader.loadDefault(
                environment: ["DOCKER_CONFIG": "relative/path"],
                homeDirectory: "/unused"
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryCredentialLookupError,
                .invalidConfiguration
            )
        }
        XCTAssertThrowsError(
            try RegistryCredentialDocumentLoader.loadDefault(
                environment: ["REGISTRY_AUTH_FILE": "relative/auth.json"],
                homeDirectory: "/unused"
            )
        ) {
            XCTAssertEqual(
                $0 as? RegistryCredentialLookupError,
                .invalidConfiguration
            )
        }
    }

    private func makeSecureDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
            "hostwright-registry-files-\(UUID().uuidString)",
            isDirectory: true
        )
        try createSecureDirectory(url)
        return url
    }

    private func createSecureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            )
        )
        guard chmod(url.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
