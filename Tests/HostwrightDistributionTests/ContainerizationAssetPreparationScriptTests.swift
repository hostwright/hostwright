import Foundation
import HostwrightCore
import XCTest

final class ContainerizationAssetPreparationScriptTests: XCTestCase {
    func testDryRunPrintsDirectManifestContractWithoutMaterializing() throws {
        try withTemporaryDirectory { root in
            let output = root.appendingPathComponent("assets", isDirectory: true)
            let result = try runScript([
                "--output", output.path,
                "--runtime-archive", root.appendingPathComponent("runtime-provenance.tar.gz").path,
                "--source-commit", String(repeating: "a", count: 40),
                "--run-id", "1234", "--attempt", "1", "--dry-run"
            ])

            XCTAssertEqual(result.status, 0, result.output)
            let contract = ContainerizationRuntimeAssetContract.self
            let expectedLines = [
                "Containerization framework: \(contract.frameworkVersion)",
                "Rebuilt Linux kernel: \(contract.kernelSHA256) (\(contract.kernelSize) bytes)",
                "Direct OCI image manifest: sha256:\(contract.initImageManifestDigest) (\(contract.initImageManifestSize) bytes)",
                "OCI image configuration: \(contract.initImageConfigurationDigest) (\(contract.initImageConfigurationSize) bytes)",
                "OCI image layer: \(contract.initImageLayerDigest) (\(contract.initImageLayerSize) bytes)",
                "Guest policy loader: \(contract.guestNetworkPolicyLoaderSHA256) (\(contract.guestNetworkPolicyLoaderSize) bytes)"
            ]
            let outputLines = result.output.split(whereSeparator: \.isNewline)
            for line in expectedLines {
                XCTAssertTrue(outputLines.contains(Substring(line)), "Missing \(line) in:\n\(result.output)")
            }
            XCTAssertTrue(result.output.contains("authenticated source \(String(repeating: "a", count: 40)) run 1234 attempt 1"))
            XCTAssertFalse(result.output.localizedCaseInsensitiveContains("kata archive"))
            XCTAssertFalse(result.output.localizedCaseInsensitiveContains("ghcr"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testRejectsRelativeAndSymlinkTraversingOutputBeforeDryRun() throws {
        let relative = try runScript(["--output", "relative/assets", "--dry-run"])
        XCTAssertEqual(relative.status, 64)
        XCTAssertTrue(relative.output.contains("normalized absolute path"))

        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            let link = root.appendingPathComponent("link", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

            let linked = try runScript([
                "--output", link.appendingPathComponent("assets", isDirectory: true).path,
                "--runtime-archive", root.appendingPathComponent("runtime-provenance.tar.gz").path,
                "--source-commit", String(repeating: "a", count: 40),
                "--run-id", "1234", "--attempt", "1",
                "--dry-run"
            ])
            XCTAssertEqual(linked.status, 66)
            XCTAssertTrue(linked.output.contains("traverses a symbolic link"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    private func scriptURL() -> URL {
        packageRoot().appendingPathComponent(
            "scripts/release/prepare-containerization-assets.sh",
            isDirectory: false
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runScript(_ arguments: [String]) throws -> (status: Int32, output: String) {
        try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptURL().path] + arguments
        )
    }

    private func run(
        executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(
            "hostwright-containerization-asset-script-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
