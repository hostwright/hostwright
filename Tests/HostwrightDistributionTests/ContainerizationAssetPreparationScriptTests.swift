import Foundation
import XCTest

final class ContainerizationAssetPreparationScriptTests: XCTestCase {
    func testDryRunValidatesLockedPlanWithoutDownloadingOrWriting() throws {
        try withTemporaryDirectory { root in
            let output = root.appendingPathComponent("assets", isDirectory: true)
            let result = try runScript(["--output", output.path, "--dry-run"])

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("Containerization framework: 0.35.0"))
            XCTAssertTrue(
                result.output.contains(
                    "f63d54507d1f18635d94475077e4c2330de4d8e05cedf25f7c38f063b0e66a91 (596775193 bytes)"
                )
            )
            XCTAssertTrue(
                result.output.contains(
                    "e3b2b9d347c2e5834d9fe5b4d615f5c0632c485d785e64f5c6b4c9b179ac168f (66895112 bytes)"
                )
            )
            XCTAssertTrue(result.output.contains("no files downloaded or written"))
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
                "--dry-run"
            ])
            XCTAssertEqual(linked.status, 66)
            XCTAssertTrue(linked.output.contains("traverses a symbolic link"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        }
    }

    func testScriptSyntaxAndExactImmutableSourceContract() throws {
        let script = scriptURL()
        let syntax = try run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-n", script.path]
        )
        XCTAssertEqual(syntax.status, 0, syntax.output)

        let source = try String(contentsOf: script, encoding: .utf8)
        for fragment in [
            "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst",
            "opt/kata/share/kata-containers/vmlinux-6.18.15-186",
            "ghcr.io/apple/containerization/vminit:0.35.0",
            "5708d65ba1914caa756a2e813831e17d7655042799310bc94efef82210c2dac6",
            "04cd14f8e6ec9617611429aaf2a91a841b27ff9eae847acaca48430f58c5e57d"
        ] {
            XCTAssertTrue(source.contains(fragment), "Missing locked asset contract: \(fragment)")
        }
        XCTAssertFalse(source.contains("HOSTWRIGHT_CONTAINERIZATION_ASSET_URL"))
        XCTAssertFalse(source.contains("curl -H \"Authorization:"))
        XCTAssertTrue(
            source.contains(#"^[A-Za-z0-9._~+/-]+={0,2}$"#),
            "The GHCR token contract must accept only bounded base64-token characters and terminal padding."
        )
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
