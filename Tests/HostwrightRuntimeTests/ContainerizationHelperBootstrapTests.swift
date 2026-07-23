import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class ContainerizationHelperBootstrapTests: XCTestCase {
    func testPreparePersistsExactPrivateConfigurationAndIsIdempotent() throws {
        let fixture = try ContainerizationHelperBootstrapFixture()

        try fixture.prepare()
        let before = try fixture.configurationIdentity()
        let beforeData = try Data(contentsOf: fixture.configurationURL)
        try fixture.prepare()

        XCTAssertEqual(try fixture.configurationIdentity(), before)
        XCTAssertEqual(try Data(contentsOf: fixture.configurationURL), beforeData)
        XCTAssertEqual(try mode(fixture.configurationURL), 0o600)
        for directory in fixture.privateDirectories {
            XCTAssertEqual(try mode(directory), 0o700, directory.path)
        }

        let document = try JSONDecoder().decode(
            BootstrapDocument.self,
            from: beforeData
        )
        XCTAssertEqual(document.schema, 1)
        XCTAssertEqual(document.framework, fixture.assetLock.frameworkVersion)
        XCTAssertEqual(document.dataRootPath, fixture.dataRootURL.path)
        XCTAssertEqual(document.runtimeDirectoryPath, fixture.runtimeDirectoryURL.path)
        XCTAssertEqual(document.kernelPath, fixture.kernelURL.path)
        XCTAssertEqual(document.kernelSHA256, fixture.assetLock.kernel.sha256)
        XCTAssertEqual(document.initImageLayoutPath, fixture.initImageLayoutURL.path)
        XCTAssertEqual(document.initImageReference, fixture.assetLock.initImageReference)
        XCTAssertEqual(
            document.initImageDescriptorDigest,
            fixture.assetLock.initImageDescriptorDigest
        )
        XCTAssertEqual(
            document.initImageVariantDigest,
            fixture.assetLock.initImageVariantDigest
        )
        XCTAssertEqual(document.rootfsSizeBytes, 4 * 1_024 * 1_024 * 1_024)
        XCTAssertNoThrow(try fixture.clientConfiguration.validateForLaunch())
        XCTAssertEqual(try fixture.temporaryConfigurationFiles(), [])
    }

    func testPrepareRefusesMismatchedExistingConfigurationWithoutOverwrite() throws {
        let fixture = try ContainerizationHelperBootstrapFixture()
        try fixture.prepare()
        let mismatched = Data(#"{"schema":999}"#.utf8)
        try mismatched.write(to: fixture.configurationURL)
        XCTAssertEqual(chmod(fixture.configurationURL.path, 0o600), 0)

        XCTAssertThrowsError(try fixture.prepare()) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .unsafeConfiguration)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.configurationURL), mismatched)
        XCTAssertEqual(try fixture.temporaryConfigurationFiles(), [])
    }

    func testPrepareRefusesSymlinkTraversalAndUnsafePrivateDirectory() throws {
        let symlinkFixture = try ContainerizationHelperBootstrapFixture()
        try symlinkFixture.createApplicationSupportParent()
        let target = symlinkFixture.rootURL.appendingPathComponent("redirect", isDirectory: true)
        try makeDirectory(target, mode: 0o700)
        XCTAssertEqual(
            symlink(target.path, symlinkFixture.supportURL.path),
            0
        )

        XCTAssertThrowsError(try symlinkFixture.prepare()) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .unsafeConfiguration)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target
                    .appendingPathComponent("config/containerization-helper.json")
                    .path
            )
        )

        let permissionsFixture = try ContainerizationHelperBootstrapFixture()
        try permissionsFixture.prepare()
        let original = try Data(contentsOf: permissionsFixture.configurationURL)
        XCTAssertEqual(chmod(permissionsFixture.supportURL.path, 0o770), 0)
        XCTAssertThrowsError(try permissionsFixture.prepare()) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .unsafeConfiguration)
        }
        XCTAssertEqual(try Data(contentsOf: permissionsFixture.configurationURL), original)
    }

    func testPrepareTreatsMissingOrReplacedAssetsAsUnavailableWithoutPersistence() throws {
        let missing = try ContainerizationHelperBootstrapFixture()
        try FileManager.default.removeItem(at: missing.layerURL)

        XCTAssertThrowsError(try missing.prepare()) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .helperLaunchFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.supportURL.path))

        let replaced = try ContainerizationHelperBootstrapFixture()
        let originalKernel = try Data(contentsOf: replaced.kernelURL)
        try FileManager.default.removeItem(at: replaced.kernelURL)
        let outside = replaced.rootURL.appendingPathComponent("outside-kernel")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: outside.path,
            contents: originalKernel,
            attributes: [.posixPermissions: 0o600]
        ))
        XCTAssertEqual(symlink(outside.path, replaced.kernelURL.path), 0)

        XCTAssertThrowsError(try replaced.prepare()) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .helperLaunchFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: replaced.supportURL.path))
    }

    func testConcurrentPrepareUsesOneExclusiveDurableConfiguration() async throws {
        let fixture = try ContainerizationHelperBootstrapFixture()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try fixture.prepare() }
            }
            try await group.waitForAll()
        }

        XCTAssertNoThrow(try fixture.clientConfiguration.validateForLaunch())
        XCTAssertEqual(try mode(fixture.configurationURL), 0o600)
        XCTAssertEqual(try fixture.temporaryConfigurationFiles(), [])
        _ = try JSONDecoder().decode(
            BootstrapDocument.self,
            from: Data(contentsOf: fixture.configurationURL)
        )
    }

    func testNonInstalledHelperLayoutFailsBeforeCreatingSupportState() throws {
        let fixture = try ContainerizationHelperBootstrapFixture()
        let invalidExecutable = fixture.prefixURL
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("hostwright-containerization-helper")
        try makeDirectory(invalidExecutable.deletingLastPathComponent(), mode: 0o700)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: invalidExecutable.path,
            contents: Data("helper".utf8),
            attributes: [.posixPermissions: 0o700]
        ))
        let invalid = try ContainerizationHelperClientConfiguration(
            executableURL: invalidExecutable,
            configurationURL: fixture.configurationURL,
            runtimeDirectoryURL: fixture.runtimeDirectoryURL
        )

        XCTAssertThrowsError(
            try ContainerizationHelperBootstrap.prepare(
                configuration: invalid,
                homeDirectoryURL: fixture.homeURL,
                assetLock: fixture.assetLock
            )
        ) { error in
            XCTAssertEqual(error as? ContainerizationHelperClientError, .helperLaunchFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.supportURL.path))
    }

    private func mode(_ url: URL) throws -> mode_t {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return metadata.st_mode & 0o7777
    }
}

private final class ContainerizationHelperBootstrapFixture: @unchecked Sendable {
    let rootURL: URL
    let homeURL: URL
    let prefixURL: URL
    let supportURL: URL
    let configurationURL: URL
    let runtimeDirectoryURL: URL
    let dataRootURL: URL
    let kernelURL: URL
    let initImageLayoutURL: URL
    let layerURL: URL
    let assetLock: ContainerizationHelperBootstrapAssetLock
    let clientConfiguration: ContainerizationHelperClientConfiguration

    var privateDirectories: [URL] {
        [
            supportURL,
            supportURL.appendingPathComponent("config", isDirectory: true),
            supportURL.appendingPathComponent("data", isDirectory: true),
            dataRootURL,
            supportURL.appendingPathComponent("run", isDirectory: true),
            runtimeDirectoryURL
        ]
    }

    init() throws {
        rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(
                "hwb-\(UUID().uuidString.lowercased().prefix(8))",
                isDirectory: true
            )
        homeURL = rootURL.appendingPathComponent("home", isDirectory: true)
        prefixURL = rootURL.appendingPathComponent("prefix", isDirectory: true)
        supportURL = homeURL
            .appendingPathComponent("Library/Application Support/Hostwright", isDirectory: true)
        configurationURL = supportURL
            .appendingPathComponent("config/containerization-helper.json")
        runtimeDirectoryURL = supportURL
            .appendingPathComponent("run/helper", isDirectory: true)
        dataRootURL = supportURL
            .appendingPathComponent("data/containerization-helper", isDirectory: true)

        try makeDirectory(rootURL, mode: 0o700)
        try makeDirectory(homeURL, mode: 0o700)
        try makeDirectory(prefixURL, mode: 0o700)
        let bin = prefixURL.appendingPathComponent("bin", isDirectory: true)
        try makeDirectory(bin, mode: 0o700)
        let helper = bin.appendingPathComponent("hostwright-containerization-helper")
        let hostwright = bin.appendingPathComponent("hostwright")
        for executable in [hostwright, helper] {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: executable.path,
                contents: Data("executable".utf8),
                attributes: [.posixPermissions: 0o700]
            ))
        }

        let assetRoot = prefixURL
            .appendingPathComponent(
                ContainerizationRuntimeAssetContract.installationRelativeRoot,
                isDirectory: true
            )
        let kernelDirectory = assetRoot.appendingPathComponent("kernel", isDirectory: true)
        initImageLayoutURL = assetRoot.appendingPathComponent("vminit", isDirectory: true)
        let blobDirectory = initImageLayoutURL
            .appendingPathComponent("blobs/sha256", isDirectory: true)
        for directory in [
            prefixURL.appendingPathComponent("share", isDirectory: true),
            prefixURL.appendingPathComponent("share/hostwright", isDirectory: true),
            assetRoot,
            kernelDirectory,
            initImageLayoutURL,
            initImageLayoutURL.appendingPathComponent("blobs", isDirectory: true),
            blobDirectory
        ] {
            try makeDirectory(directory, mode: 0o700)
        }

        let kernel = Data("fixture-kernel".utf8)
        let imageIndex = Data("fixture-index".utf8)
        let imageVariant = Data("fixture-variant".utf8)
        let imageConfiguration = Data("fixture-configuration".utf8)
        let imageLayer = Data("fixture-layer".utf8)
        let indexLock = Self.lockedFile(data: imageIndex)
        let variantLock = Self.lockedFile(data: imageVariant)
        let configurationLock = Self.lockedFile(data: imageConfiguration)
        let layerLock = Self.lockedFile(data: imageLayer)
        assetLock = ContainerizationHelperBootstrapAssetLock(
            frameworkVersion: ContainerizationRuntimeAssetContract.frameworkVersion,
            kernel: .init(
                name: ContainerizationRuntimeAssetContract.kernelFileName,
                sha256: Self.sha256(kernel),
                size: Int64(kernel.count)
            ),
            initImageReference: ContainerizationRuntimeAssetContract.initImageReference,
            initImageIndex: indexLock,
            initImageVariant: variantLock,
            initImageConfiguration: configurationLock,
            initImageLayer: layerLock
        )

        kernelURL = kernelDirectory.appendingPathComponent(assetLock.kernel.name)
        layerURL = blobDirectory.appendingPathComponent(assetLock.initImageLayer.name)
        try Self.write(kernel, to: kernelURL)
        try Self.write(imageIndex, to: blobDirectory.appendingPathComponent(indexLock.name))
        try Self.write(imageVariant, to: blobDirectory.appendingPathComponent(variantLock.name))
        try Self.write(
            imageConfiguration,
            to: blobDirectory.appendingPathComponent(configurationLock.name)
        )
        try Self.write(imageLayer, to: layerURL)
        try Self.write(
            Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8),
            to: initImageLayoutURL.appendingPathComponent("oci-layout")
        )
        let rootIndex: [String: Any] = [
            "schemaVersion": 2,
            "manifests": [[
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": assetLock.initImageDescriptorDigest,
                "size": imageIndex.count,
                "annotations": [
                    "org.opencontainers.image.ref.name": assetLock.initImageReference
                ]
            ]]
        ]
        try Self.write(
            JSONSerialization.data(withJSONObject: rootIndex, options: [.sortedKeys]),
            to: initImageLayoutURL.appendingPathComponent("index.json")
        )

        clientConfiguration = try ContainerizationHelperClientConfiguration.installed(
            hostExecutableURL: hostwright,
            homeDirectoryURL: homeURL
        )
        XCTAssertEqual(clientConfiguration.executableURL, helper)
        XCTAssertEqual(clientConfiguration.configurationURL, configurationURL)
        XCTAssertEqual(clientConfiguration.runtimeDirectoryURL, runtimeDirectoryURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func prepare() throws {
        try ContainerizationHelperBootstrap.prepare(
            configuration: clientConfiguration,
            homeDirectoryURL: homeURL,
            assetLock: assetLock
        )
    }

    func createApplicationSupportParent() throws {
        try makeDirectory(homeURL.appendingPathComponent("Library", isDirectory: true), mode: 0o700)
        try makeDirectory(
            homeURL.appendingPathComponent("Library/Application Support", isDirectory: true),
            mode: 0o700
        )
    }

    func temporaryConfigurationFiles() throws -> [String] {
        let configDirectory = configurationURL.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: configDirectory.path)
            .filter { $0.hasPrefix(".containerization-helper.json.") }
            .sorted()
    }

    func configurationIdentity() throws -> [UInt64] {
        var metadata = stat()
        guard lstat(configurationURL.path, &metadata) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return [UInt64(metadata.st_dev), UInt64(metadata.st_ino)]
    }

    private static func lockedFile(
        data: Data
    ) -> ContainerizationHelperBootstrapAssetLock.File {
        let digest = sha256(data)
        return .init(name: digest, sha256: digest, size: Int64(data.count))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ data: Data, to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ))
    }
}

private struct BootstrapDocument: Decodable {
    let schema: Int
    let framework: String
    let dataRootPath: String
    let runtimeDirectoryPath: String
    let kernelPath: String
    let kernelSHA256: String
    let initImageLayoutPath: String
    let initImageReference: String
    let initImageDescriptorDigest: String
    let initImageVariantDigest: String
    let rootfsSizeBytes: UInt64
}

private func makeDirectory(_ url: URL, mode: mode_t) throws {
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: mode)]
    )
    guard chmod(url.path, mode) == 0 else {
        throw CocoaError(.fileWriteNoPermission)
    }
}
