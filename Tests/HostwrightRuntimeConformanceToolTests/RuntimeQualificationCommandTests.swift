import Foundation
import HostwrightCore
import HostwrightRuntime
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationCommandTests: XCTestCase {
    private let localImage = "docker.io/library/python:alpine"

    func testVersionIsExactSingleLineAndDoesNotInvokeQualification() async {
        let result = await RuntimeQualificationCommand.run(arguments: ["--version"])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "hostwright-runtime-conformance \(HostwrightIdentity.version)\n")
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(result.standardOutput.split(separator: "\n").count, 1)
    }

    func testParserAcceptsOnlyLockedProviderVersionPairs() throws {
        try withTemporaryDirectory { directory in
            let cli = try RuntimeQualificationCommand.parse([
                "conformance",
                "--provider", "apple-container-cli",
                "--expected-version", "1.0.0",
                "--local-image", localImage,
                "--output", directory.appendingPathComponent("cli.json").path,
            ])
            XCTAssertEqual(cli.operation, .conformance)
            XCTAssertEqual(cli.providerID, .appleContainerCLI)
            XCTAssertEqual(cli.expectedVersion, "1.0.0")
            XCTAssertEqual(cli.localImage, localImage)

            let helper = try RuntimeQualificationCommand.parse([
                "conformance",
                "--provider", "apple-containerization",
                "--expected-version", ContainerizationRuntimeAssetContract.frameworkVersion,
                "--local-image", localImage,
                "--output", directory.appendingPathComponent("helper.json").path,
            ])
            XCTAssertEqual(helper.providerID, .appleContainerization)
            XCTAssertEqual(
                helper.expectedVersion,
                ContainerizationRuntimeAssetContract.frameworkVersion
            )

            for version in ["1.0.0", "1.1.0"] {
                let options = try RuntimeQualificationCommand.parse([
                    "conformance",
                    "--provider", "apple-container-cli",
                    "--expected-version", version,
                    "--local-image", localImage,
                    "--output", directory.appendingPathComponent("cli-\(version).json").path,
                ])
                XCTAssertEqual(options.expectedVersion, version)
            }
        }
    }

    func testParserAcceptsLockedMigrationAndProviderSpecificRecovery() throws {
        try withTemporaryDirectory { directory in
            let migration = try RuntimeQualificationCommand.parse([
                "migration",
                "--source-provider", "apple-container-cli",
                "--target-provider", "apple-containerization",
                "--expected-source-version", "1.1.0",
                "--expected-target-version", ContainerizationRuntimeAssetContract.frameworkVersion,
                "--local-image", localImage,
                "--output", directory.appendingPathComponent("migration.json").path,
            ])
            XCTAssertEqual(migration.operation, .migration)
            XCTAssertEqual(migration.sourceProviderID, .appleContainerCLI)
            XCTAssertEqual(migration.targetProviderID, .appleContainerization)
            XCTAssertEqual(migration.expectedSourceVersion, "1.1.0")
            XCTAssertEqual(
                migration.expectedTargetVersion,
                ContainerizationRuntimeAssetContract.frameworkVersion
            )

            let cliRecovery = try RuntimeQualificationCommand.parse([
                "recovery",
                "--provider", "apple-container-cli",
                "--expected-version", "1.1.0",
                "--scenario", "cli-service-restart",
                "--local-image", localImage,
                "--output", directory.appendingPathComponent("cli-recovery.json").path,
            ])
            XCTAssertEqual(cliRecovery.operation, .recovery)
            XCTAssertEqual(cliRecovery.providerID, .appleContainerCLI)
            XCTAssertEqual(cliRecovery.scenario, "cli-service-restart")

            let helperRecovery = try RuntimeQualificationCommand.parse([
                "recovery",
                "--provider", "apple-containerization",
                "--expected-version", ContainerizationRuntimeAssetContract.frameworkVersion,
                "--scenario", "helper-restart",
                "--local-image", localImage,
                "--output", directory.appendingPathComponent("helper-recovery.json").path,
            ])
            XCTAssertEqual(helperRecovery.providerID, .appleContainerization)
            XCTAssertEqual(helperRecovery.scenario, "helper-restart")
        }
    }

    func testParserRejectsUnsupportedOrAmbiguousQualificationRequests() throws {
        try withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("evidence.json").path
            let cases: [[String]] = [
                [],
                ["--version", "extra"],
                [
                    "conformance", "--provider", "unknown-provider",
                    "--expected-version", "1.1.0", "--local-image", localImage,
                    "--output", output,
                ],
                [
                    "conformance", "--provider", "apple-container-cli",
                    "--expected-version", "1.2.0", "--local-image", localImage,
                    "--output", output,
                ],
                [
                    "conformance", "--provider", "apple-containerization",
                    "--expected-version", "1.1.0", "--local-image", localImage,
                    "--output", output,
                ],
                [
                    "migration", "--source-provider", "apple-container-cli",
                    "--target-provider", "apple-container-cli",
                    "--expected-source-version", "1.1.0",
                    "--expected-target-version", "1.1.0",
                    "--local-image", localImage, "--output", output,
                ],
                [
                    "recovery", "--provider", "apple-container-cli",
                    "--expected-version", "1.1.0", "--scenario", "helper-restart",
                    "--local-image", localImage, "--output", output,
                ],
                [
                    "recovery", "--provider", "apple-containerization",
                    "--expected-version", ContainerizationRuntimeAssetContract.frameworkVersion,
                    "--scenario", "cli-service-restart", "--local-image", localImage,
                    "--output", output,
                ],
                [
                    "conformance", "--provider", "apple-container-cli",
                    "--provider", "apple-container-cli", "--expected-version", "1.1.0",
                    "--local-image", localImage, "--output", output,
                ],
                [
                    "conformance", "--provider", "apple-container-cli",
                    "--expected-version", "1.1.0", "--local-image", "unsafe\nimage",
                    "--output", output,
                ],
                [
                    "conformance", "--provider", "apple-container-cli",
                    "--expected-version", "1.1.0", "--local-image", localImage,
                    "--output", directory.appendingPathComponent("nested/../evidence.json").path,
                ],
            ]

            for arguments in cases {
                assertUsageError(arguments)
            }
        }
    }

    func testExistingOutputIsRefusedWithoutOverwriteOrQualification() async throws {
        try await withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("evidence.json")
            let sentinel = Data("do-not-overwrite\n".utf8)
            try sentinel.write(to: output, options: .withoutOverwriting)

            let result = await RuntimeQualificationCommand.run(arguments: [
                "conformance",
                "--provider", "apple-container-cli",
                "--expected-version", "1.1.0",
                "--local-image", localImage,
                "--output", output.path,
            ])

            XCTAssertEqual(result.exitCode, 64)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.hasPrefix("USAGE: "))
            XCTAssertEqual(try Data(contentsOf: output), sentinel)
        }
    }

    func testDanglingSymlinkOutputAndSymlinkParentAreRefusedFailClosed() throws {
        try withTemporaryDirectory { directory in
            let missingTarget = directory.appendingPathComponent("missing-target.json")
            let danglingOutput = directory.appendingPathComponent("evidence.json")
            try FileManager.default.createSymbolicLink(
                atPath: danglingOutput.path,
                withDestinationPath: missingTarget.path
            )
            assertUsageError(conformanceArguments(output: danglingOutput.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))

            let realParent = directory.appendingPathComponent("real-parent", isDirectory: true)
            try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
            let linkedParent = directory.appendingPathComponent("linked-parent", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                atPath: linkedParent.path,
                withDestinationPath: realParent.path
            )
            let linkedOutput = linkedParent.appendingPathComponent("evidence.json")
            assertUsageError(conformanceArguments(output: linkedOutput.path))
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: realParent.appendingPathComponent("evidence.json").path
                )
            )
        }
    }

    func testInvalidCommandProducesNoPassingReport() async throws {
        try await withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("evidence.json")
            let result = await RuntimeQualificationCommand.run(arguments: [
                "conformance",
                "--provider", "apple-container-cli",
                "--expected-version", "future",
                "--local-image", localImage,
                "--output", output.path,
            ])

            XCTAssertEqual(result.exitCode, 64)
            XCTAssertEqual(result.standardOutput, "")
            XCTAssertTrue(result.standardError.contains("unsupported version"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(result.standardError.contains("evidence passed"))
        }
    }

    private func conformanceArguments(output: String) -> [String] {
        [
            "conformance",
            "--provider", "apple-container-cli",
            "--expected-version", "1.1.0",
            "--local-image", localImage,
            "--output", output,
        ]
    }

    private func assertUsageError(
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RuntimeQualificationCommand.parse(arguments),
            file: file,
            line: line
        ) { error in
            guard case RuntimeQualificationCommandError.usage = error else {
                return XCTFail("Expected a usage error, got \(error)", file: file, line: line)
            }
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-runtime-conformance-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(
        _ body: (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-runtime-conformance-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }
}
