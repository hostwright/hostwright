import Darwin
import Foundation
import XCTest
@testable import HostwrightDistribution

final class DistributionContainerizationAssetSecurityTests: XCTestCase {
    func testLoadRejectsNonPrivateRootAndIntermediateDirectory() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.path
            )
            XCTAssertThrowsError(try DistributionContainerizationAssets.load(root: root)) {
                guard case DistributionError.unsafePath = $0 else {
                    return XCTFail("Expected unsafePath, received \($0)")
                }
            }

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            let kernel = root.appendingPathComponent("kernel", isDirectory: true)
            try FileManager.default.createDirectory(at: kernel, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o770],
                ofItemAtPath: kernel.path
            )
            XCTAssertThrowsError(try DistributionContainerizationAssets.load(root: root)) {
                guard case DistributionError.unsafePath = $0 else {
                    return XCTFail("Expected unsafePath, received \($0)")
                }
            }
        }
    }

    func testLoadRejectsSymlinkedIntermediateDirectory() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("assets", isDirectory: true)
            let target = temporary.appendingPathComponent("kernel-target", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("kernel", isDirectory: true),
                withDestinationURL: target
            )

            XCTAssertThrowsError(try DistributionContainerizationAssets.load(root: root)) {
                guard case DistributionError.unsafePath = $0 else {
                    return XCTFail("Expected unsafePath, received \($0)")
                }
            }
        }
    }

    func testLoadRejectsWritableAssetFile() throws {
        try withTemporaryDirectory { temporary in
            let root = temporary.appendingPathComponent("assets", isDirectory: true)
            let kernelDirectory = root.appendingPathComponent("kernel", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: kernelDirectory,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: kernelDirectory.path
            )
            let kernel = kernelDirectory.appendingPathComponent(
                DistributionContainerizationAssets.kernelFileName
            )
            try Data("not-the-locked-kernel\n".utf8).write(
                to: kernel,
                options: .withoutOverwriting
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: kernel.path)

            XCTAssertThrowsError(try DistributionContainerizationAssets.load(root: root)) {
                guard case DistributionError.invalidArtifact = $0 else {
                    return XCTFail("Expected invalidArtifact, received \($0)")
                }
            }
        }
    }

    func testValidatedCopyRejectsPathReplacement() throws {
        try withTemporaryDirectory { temporary in
            let source = temporary.appendingPathComponent("source")
            let replacement = temporary.appendingPathComponent("replacement")
            let destination = temporary.appendingPathComponent("output/destination")
            try Data("trusted\n".utf8).write(to: source, options: .withoutOverwriting)
            try Data("hostile\n".utf8).write(to: replacement, options: .withoutOverwriting)
            var metadata = stat()
            XCTAssertEqual(lstat(source.path, &metadata), 0)
            let validatedSource = try DistributionFileSystem.bindValidatedSource(
                source,
                metadata: metadata
            )
            XCTAssertEqual(rename(replacement.path, source.path), 0)

            XCTAssertThrowsError(
                try DistributionFileSystem.copyRegularFile(
                    from: validatedSource,
                    to: destination,
                    mode: 0o644
                )
            ) { error in
                guard case let DistributionError.invalidArtifact(message) = error else {
                    return XCTFail("Expected invalidArtifact, received \(error)")
                }
                XCTAssertTrue(message.contains("changed after validation"))
            }
            XCTAssertFalse(DistributionFileSystem.entryExists(destination))
        }
    }

    func testValidatedCopyRejectsParentDirectoryDrift() throws {
        try withTemporaryDirectory { temporary in
            let source = temporary.appendingPathComponent("source")
            let destination = temporary.appendingPathComponent("output/destination")
            try Data("trusted\n".utf8).write(to: source, options: .withoutOverwriting)
            var fileMetadata = stat()
            var directoryMetadata = stat()
            XCTAssertEqual(lstat(source.path, &fileMetadata), 0)
            XCTAssertEqual(lstat(temporary.path, &directoryMetadata), 0)
            let validatedSource = try DistributionFileSystem.bindValidatedSource(
                source,
                metadata: fileMetadata,
                directoryIdentities: [
                    DistributionValidatedSourceIdentity(metadata: directoryMetadata)
                ]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: temporary.path
            )

            XCTAssertThrowsError(
                try DistributionFileSystem.copyRegularFile(
                    from: validatedSource,
                    to: destination,
                    mode: 0o644
                )
            ) { error in
                guard case let DistributionError.invalidArtifact(message) = error else {
                    return XCTFail("Expected invalidArtifact, received \(error)")
                }
                XCTAssertTrue(message.contains("source directory changed after validation"))
            }
            XCTAssertFalse(DistributionFileSystem.entryExists(destination))
        }
    }

    func testValidatedCopyStreamsTheBoundFileWithExactMode() throws {
        try withTemporaryDirectory { temporary in
            let source = temporary.appendingPathComponent("source")
            let destination = temporary.appendingPathComponent("output/destination")
            let contents = Data("trusted\n".utf8)
            try contents.write(to: source, options: .withoutOverwriting)
            var metadata = stat()
            var directoryMetadata = stat()
            XCTAssertEqual(lstat(source.path, &metadata), 0)
            XCTAssertEqual(lstat(temporary.path, &directoryMetadata), 0)

            try DistributionFileSystem.copyRegularFile(
                from: try DistributionFileSystem.bindValidatedSource(
                    source,
                    metadata: metadata,
                    directoryIdentities: [
                        DistributionValidatedSourceIdentity(metadata: directoryMetadata)
                    ]
                ),
                to: destination,
                mode: 0o640
            )

            XCTAssertEqual(try Data(contentsOf: destination), contents)
            XCTAssertEqual(try DistributionFileSystem.mode(of: destination), 0o640)
        }
    }

    func testValidatedCopyRejectsInPlaceMutation() throws {
        try withTemporaryDirectory { temporary in
            let source = temporary.appendingPathComponent("source")
            let destination = temporary.appendingPathComponent("output/destination")
            try Data("trusted\n".utf8).write(to: source, options: .withoutOverwriting)
            var metadata = stat()
            XCTAssertEqual(lstat(source.path, &metadata), 0)
            let validatedSource = try DistributionFileSystem.bindValidatedSource(
                source,
                metadata: metadata
            )

            let handle = try FileHandle(forWritingTo: source)
            try handle.write(contentsOf: Data("mutated\n".utf8))
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)

            XCTAssertThrowsError(
                try DistributionFileSystem.copyRegularFile(
                    from: validatedSource,
                    to: destination,
                    mode: 0o644
                )
            ) { error in
                guard case let DistributionError.invalidArtifact(message) = error else {
                    return XCTFail("Expected invalidArtifact, received \(error)")
                }
                XCTAssertTrue(message.contains("changed after validation"))
            }
            XCTAssertFalse(DistributionFileSystem.entryExists(destination))
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "hostwright-distribution-asset-security-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
