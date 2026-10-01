import Foundation
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
            XCTAssertTrue(result.output.contains("Containerization framework: 0.35.0"))
            XCTAssertTrue(result.output.contains("Rebuilt Linux kernel: 55f86b8394c1d46551836f5c1d3525cdc8d505aeb9bb630c608edb564674239d (16148992 bytes)"))
            XCTAssertTrue(result.output.contains("Direct OCI image manifest: sha256:b3b054594e1b3bf6a21683f2a26074ceff73409ac538b86b2e9513e849d9b325 (406 bytes)"))
            XCTAssertTrue(result.output.contains("OCI image configuration: d5ed2e2c7255c07724bb8a2eded642eb3a4f7a7d4b83441b7075f6682336738e (151 bytes)"))
            XCTAssertTrue(result.output.contains("OCI image layer: ffd2251deae40a37b6ba2728ebd4e47edf3ef90a16c1149da28b1f0411d2980c (67223020 bytes)"))
            XCTAssertTrue(result.output.contains("Guest policy loader: a411dbcf1efaaf0ea0da17d76e3376a92b99037a8cb00af6588e8ecc6f3f7e99 (2949246 bytes)"))
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
