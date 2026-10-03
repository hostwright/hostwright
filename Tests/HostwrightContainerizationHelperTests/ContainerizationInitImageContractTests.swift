import Containerization
import ContainerizationOCI
import CryptoKit
import Foundation
import HostwrightCore
import XCTest

@testable import HostwrightRuntime
@testable import HostwrightContainerizationHelper

final class ContainerizationInitImageContractTests: XCTestCase {
    func testPinnedConfigurationMatchesSDKImportedIndexAndManifestVariant() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestDigest = "sha256:\(ContainerizationRuntimeAssetContract.initImageManifestDigest)"
        let index = Index(
            manifests: [Descriptor(
                mediaType: MediaTypes.imageManifest,
                digest: manifestDigest,
                size: ContainerizationRuntimeAssetContract.initImageManifestSize,
                platform: Platform(arch: "arm64", os: "linux")
            )],
            annotations: [AnnotationKeys.containerizationIndexIndirect: "true"]
        )
        let written = try ContentWriter(for: root).create(from: index)
        let importedDigest = written.digest.digestString

        XCTAssertEqual(written.size, ContainerizationRuntimeAssetContract.initImageImportedIndexSize)
        XCTAssertEqual(ContainerizationRuntimeAssetContract.initImageDescriptorDigest, importedDigest)
        XCTAssertEqual(ContainerizationHelperBootstrapAssetLock.pinned.initImageDescriptorDigest, importedDigest)
        XCTAssertEqual(ContainerizationHelperBootstrapAssetLock.pinned.initImageVariantDigest, manifestDigest)
        XCTAssertNotEqual(importedDigest, manifestDigest)
    }

    func testSDKDirectManifestImportProducesAuthenticatedIndirectIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = root.appendingPathComponent("layout", isDirectory: true)
        let blobs = layout.appendingPathComponent("blobs/sha256", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let config = Data(#"{"architecture":"arm64","os":"linux","config":{},"rootfs":{"type":"layers","diff_ids":[]}}"#.utf8)
        let configurationDigest = digest(config)
        try config.write(to: blobs.appendingPathComponent(String(configurationDigest.dropFirst(7))))
        let manifest = Manifest(
            config: Descriptor(mediaType: MediaTypes.imageConfig, digest: configurationDigest, size: Int64(config.count)),
            layers: []
        )
        let manifestResult = try ContentWriter(for: blobs).create(from: manifest)
        let manifestDescriptor = Descriptor(
            mediaType: MediaTypes.imageManifest,
            digest: manifestResult.digest.digestString,
            size: manifestResult.size
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Index(manifests: [manifestDescriptor])).write(to: layout.appendingPathComponent("index.json"))
        try Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8).write(to: layout.appendingPathComponent("oci-layout"))

        let store = try ImageStore(path: root.appendingPathComponent("images", isDirectory: true))
        let imported = try await store.load(from: layout)
        let image = try XCTUnwrap(imported.first)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(image.reference, "untagged@\(manifestDescriptor.digest)")
        XCTAssertNotEqual(image.descriptor.digest, manifestDescriptor.digest)
        let variant = try await image.descriptor(for: Platform(arch: "arm64", os: "linux"))
        XCTAssertEqual(variant.digest, manifestDescriptor.digest)

        let expectedRoot = try ContentWriter(for: root).create(from: Index(
            manifests: [Descriptor(
                mediaType: manifestDescriptor.mediaType,
                digest: manifestDescriptor.digest,
                size: manifestDescriptor.size,
                platform: Platform(arch: "arm64", os: "linux")
            )],
            annotations: [AnnotationKeys.containerizationIndexIndirect: "true"]
        ))
        XCTAssertEqual(image.descriptor.digest, expectedRoot.digest.digestString)
        XCTAssertEqual(image.descriptor.size, expectedRoot.size)

        let accepted = try await ContainerizationHelperInitImage.require(
            configuration: configuration(root: root, layout: layout, reference: image.reference,
                                         descriptor: image.descriptor.digest, variant: manifestDescriptor.digest),
            imageStore: store
        )
        XCTAssertEqual(accepted.descriptor, image.descriptor)
        for (descriptor, variant) in [
            (manifestDescriptor.digest, manifestDescriptor.digest),
            (image.descriptor.digest, configurationDigest)
        ] {
            do {
                _ = try await ContainerizationHelperInitImage.require(
                    configuration: configuration(root: root, layout: layout, reference: image.reference,
                                                 descriptor: descriptor, variant: variant),
                    imageStore: store
                )
                XCTFail("Mismatched root or variant must be rejected")
            } catch {
                XCTAssertEqual(error as? ContainerizationHelperConfigurationError, .assetDigestMismatch)
            }
        }
        let retainedImages = try await store.list()
        XCTAssertEqual(retainedImages.count, 1)
    }

    private func configuration(
        root: URL, layout: URL, reference: String, descriptor: String, variant: String
    ) -> ContainerizationHelperConfiguration {
        ContainerizationHelperConfiguration(
            schema: 1,
            framework: ContainerizationRuntimeAssetContract.frameworkVersion,
            dataRootPath: root.appendingPathComponent("data").path,
            runtimeDirectoryPath: root.appendingPathComponent("run").path,
            kernelPath: root.appendingPathComponent("kernel").path,
            kernelSHA256: ContainerizationRuntimeAssetContract.kernelSHA256,
            initImageLayoutPath: layout.path,
            initImageReference: reference,
            initImageDescriptorDigest: descriptor,
            initImageVariantDigest: variant,
            rootfsSizeBytes: 1_073_741_824
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-init-contract-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func digest(_ data: Data) -> String {
        "sha256:" + CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
