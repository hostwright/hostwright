import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime

extension HostwrightCLITests {
    func testMigratePreviewConvertsLegacyFlatResourcesToV3WithoutWritingSource() {
        let source = """
        version: 2
        project: demo
        services:
          api:
            image: local/demo:latest
            resources: {cpus: 2, memory: 512MiB}
        """
        let files = FileBox(files: [HostwrightIdentity.manifestFileName: source])

        let textResult = HostwrightCLI.run(
            arguments: ["migrate", "preview", HostwrightIdentity.manifestFileName],
            environment: environment(files: files)
        )

        XCTAssertEqual(textResult.exitCode, 0)
        XCTAssertTrue(textResult.standardOutput.contains("version: 3"))
        XCTAssertTrue(textResult.standardOutput.contains("requests:"))
        XCTAssertTrue(textResult.standardOutput.contains("limits:"))
        XCTAssertEqual(files.files[HostwrightIdentity.manifestFileName], source)

        let jsonResult = HostwrightCLI.run(
            arguments: [
                "migrate", "preview", HostwrightIdentity.manifestFileName, "--json"
            ],
            environment: environment(files: files)
        )
        XCTAssertEqual(jsonResult.exitCode, 0)
        XCTAssertTrue(jsonResult.standardOutput.contains(#""targetVersion":3"#))
        XCTAssertTrue(jsonResult.standardOutput.contains("legacy flat resource fields"))
    }

    func testExtensionCheckJSONErrorUsesStableCodeAndDoesNotCreateState() throws {
        let missingDeclaration = "/tmp/hostwright-extension-missing-\(UUID().uuidString).json"
        let result = HostwrightCLI.run(
            arguments: [
                "extension", "check",
                "--declaration", missingDeclaration,
                "--executable", "/tmp/hostwright-extension-missing",
                "--output", "json"
            ],
            environment: environment(files: FileBox())
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(result.standardOutput, "")
        let object = try jsonObject(result.standardError)
        XCTAssertEqual(object["kind"] as? String, "error")
        XCTAssertEqual(object["code"] as? String, HostwrightErrorCode.extensionInvalid.rawValue)
        XCTAssertEqual(object["exitCode"] as? Int, Int(CLIExitCode.validation.rawValue))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDeclaration))
    }

    func testInitCreatesStarterManifestWithoutOverwriting() {
        let initFiles = FileBox()
        let initResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: initFiles))

        XCTAssertEqual(initResult.exitCode, 0)
        XCTAssertTrue(initFiles.files[HostwrightIdentity.manifestFileName]?.contains("project: api-local") == true)
        XCTAssertNoThrow(try ManifestValidator.validated(XCTUnwrap(initFiles.files[HostwrightIdentity.manifestFileName])))

        let existingFiles = FileBox(files: [HostwrightIdentity.manifestFileName: "project: existing\nservices:\n"])
        let overwriteResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: existingFiles))

        XCTAssertEqual(overwriteResult.exitCode, CLIExitCode.commandUsage.rawValue)
        XCTAssertTrue(overwriteResult.standardError.contains("HW-CLI-002"))
        XCTAssertEqual(existingFiles.files[HostwrightIdentity.manifestFileName], "project: existing\nservices:\n")
    }

    func testImportStackFailsClosedForMissingV3ResourcesWithoutWritingFiles() throws {
        let files = FileBox(files: ["compose.yaml": safeStackFile])

        let result = HostwrightCLI.run(arguments: ["import-stack", "compose.yaml"], environment: environment(files: files))

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("resources must declare explicit requests and limits"))
        XCTAssertNil(files.files[HostwrightIdentity.manifestFileName])
        XCTAssertEqual(files.files, ["compose.yaml": safeStackFile])
    }

    func testImportStackJSONMapsComposeCapacityDeterministicallyWithoutWritingFiles() throws {
        let stack = """
        name: demo
        services:
          api:
            image: ghcr.io/example/api:latest
            deploy:
              resources:
                reservations:
                  cpus: "1"
                  memory: 512m
                limits:
                  cpus: "2"
                  memory: 1g

        """
        let files = FileBox(files: ["compose.yaml": stack])

        let result = HostwrightCLI.run(arguments: ["import-stack", "compose.yaml", "--output", "json"], environment: environment(files: files))
        let repeated = HostwrightCLI.run(arguments: ["import-stack", "compose.yaml", "--output", "json"], environment: environment(files: files))

        XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(repeated, result)
        XCTAssertEqual(files.files, ["compose.yaml": stack])
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["kind"] as? String, "composeImport")
        XCTAssertEqual(object["sourcePath"] as? String, "compose.yaml")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["contractVersion"] as? String, "v1")
        XCTAssertEqual(object["succeeded"] as? Bool, true)
        XCTAssertTrue((object["manifestText"] as? String)?.contains("requests:\n        cpus: 1\n        memory: 512MiB") == true)
        XCTAssertTrue((object["canonicalComposeText"] as? String)?.contains("memory: \"512m\"") == true)
        let lossReport = try XCTUnwrap(object["lossReport"] as? [String: Any])
        XCTAssertEqual(lossReport["operation"] as? String, "import")
        let losses = try XCTUnwrap(lossReport["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.count, 0)
    }

    func testImportStackJSONErrorsUseVersionedComposeLossEnvelopeAndFailClosed() throws {
        let stack = """
        name: demo
        services:
          api:
            image: ghcr.io/example/api:latest
            network_mode: host

        """
        let files = FileBox(files: ["compose.yaml": stack])

        let result = HostwrightCLI.run(arguments: ["import-stack", "compose.yaml", "--output", "json"], environment: environment(files: files))

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(files.files, ["compose.yaml": stack])
        let object = try jsonObject(result.standardError)
        XCTAssertEqual(object["kind"] as? String, "composeImport")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["contractVersion"] as? String, "v1")
        XCTAssertEqual(object["succeeded"] as? Bool, false)
        XCTAssertTrue(object["manifestText"] is NSNull)
        XCTAssertTrue(object["canonicalComposeText"] is NSNull)
        let lossReport = try XCTUnwrap(object["lossReport"] as? [String: Any])
        XCTAssertEqual(lossReport["operation"] as? String, "import")
        let losses = try XCTUnwrap(lossReport["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.first?["code"] as? String, "HW-COMPOSE-001")
        XCTAssertEqual(losses.first?["path"] as? String, "$.services.api.network_mode")
        XCTAssertEqual(losses.first?["policyReasonCode"] as? String, "secureExposureUnsupported")
        XCTAssertTrue((losses.first?["message"] as? String)?.contains("network_mode") == true)
    }

    func testExportStackTextAndJSONAreDeterministicAndReadOnly() throws {
        let textFiles = FileBox(files: ["hostwright.yaml": composeExportManifest])
        let textResult = HostwrightCLI.run(
            arguments: ["export-stack", "hostwright.yaml"],
            environment: composeReadOnlyEnvironment(files: textFiles)
        )

        XCTAssertEqual(textResult.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(textResult.standardError, "")
        XCTAssertTrue(textResult.standardOutput.contains("name: \"compose-cli\""))
        XCTAssertTrue(textResult.standardOutput.contains("cpus: \"1\""))
        XCTAssertTrue(textResult.standardOutput.contains("memory: \"512m\""))
        XCTAssertEqual(textFiles.readCounts, ["hostwright.yaml": 1])
        XCTAssertEqual(textFiles.writeCount, 0)

        let jsonFiles = FileBox(files: ["hostwright.yaml": composeExportManifest])
        let jsonEnvironment = composeReadOnlyEnvironment(files: jsonFiles)
        let result = HostwrightCLI.run(
            arguments: ["export-stack", "hostwright.yaml", "--output", "json"],
            environment: jsonEnvironment
        )
        let repeated = HostwrightCLI.run(
            arguments: ["export-stack", "hostwright.yaml", "--output", "json"],
            environment: jsonEnvironment
        )

        XCTAssertEqual(repeated, result)
        XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(jsonFiles.readCounts, ["hostwright.yaml": 2])
        XCTAssertEqual(jsonFiles.writeCount, 0)
        let object = try jsonObject(result.standardOutput)
        XCTAssertEqual(object["kind"] as? String, "composeExport")
        XCTAssertEqual(object["sourcePath"] as? String, "hostwright.yaml")
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["contractVersion"] as? String, "v1")
        XCTAssertEqual(object["succeeded"] as? Bool, true)
        XCTAssertTrue((object["composeText"] as? String)?.contains("memory: \"1g\"") == true)
        let lossReport = try XCTUnwrap(object["lossReport"] as? [String: Any])
        XCTAssertEqual(lossReport["operation"] as? String, "export")
        XCTAssertEqual((lossReport["losses"] as? [[String: Any]])?.count, 0)
    }

    func testExportStackRejectsUnrepresentableManifestWithExactComposeLoss() throws {
        let files = FileBox(files: ["hostwright.yaml": composeUnrepresentableManifest])
        let environment = composeReadOnlyEnvironment(files: files)
        let text = HostwrightCLI.run(
            arguments: ["export-stack", "hostwright.yaml"],
            environment: environment
        )
        let json = HostwrightCLI.run(
            arguments: ["export-stack", "hostwright.yaml", "--output", "json"],
            environment: environment
        )

        XCTAssertEqual(text.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(text.standardOutput, "")
        XCTAssertTrue(text.standardError.contains("HW-COMPOSE-003"))
        XCTAssertTrue(text.standardError.contains("$.imagePolicy"))
        XCTAssertEqual(json.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(json.standardOutput, "")
        let object = try jsonObject(json.standardError)
        XCTAssertEqual(object["kind"] as? String, "composeExport")
        XCTAssertEqual(object["succeeded"] as? Bool, false)
        XCTAssertTrue(object["composeText"] is NSNull)
        let report = try XCTUnwrap(object["lossReport"] as? [String: Any])
        let losses = try XCTUnwrap(report["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.map { $0["code"] as? String }, ["HW-COMPOSE-003"])
        XCTAssertEqual(losses.map { $0["path"] as? String }, ["$.imagePolicy"])
        XCTAssertEqual(files.readCounts, ["hostwright.yaml": 2])
        XCTAssertEqual(files.writeCount, 0)
    }

    func testComposeJSONParseFailuresRetainTypedEnvelopes() throws {
        let invalidDocuments = [
            "malformed": "version: [",
            "oversized": String(repeating: "x", count: ManifestParser.maximumUTF8Bytes + 1),
            "duplicate-key": "version: 3\nproject: first\nproject: second\nservices: {}\n",
        ]
        for (name, invalid) in invalidDocuments {
            let export = HostwrightCLI.run(
                arguments: ["export-stack", "./manifest.yaml", "--output", "json"],
                environment: composeReadOnlyEnvironment(
                    files: FileBox(files: ["manifest.yaml": invalid])
                )
            )
            XCTAssertEqual(export.exitCode, CLIExitCode.validation.rawValue, name)
            XCTAssertEqual(export.standardOutput, "", name)
            let exportObject = try jsonObject(export.standardError)
            XCTAssertEqual(exportObject["kind"] as? String, "composeExport", name)
            XCTAssertEqual(exportObject["sourcePath"] as? String, "manifest.yaml", name)
            XCTAssertEqual(exportObject["succeeded"] as? Bool, false, name)
            let exportReport = try XCTUnwrap(
                exportObject["lossReport"] as? [String: Any],
                name
            )
            XCTAssertEqual(exportReport["operation"] as? String, "export", name)
            XCTAssertFalse(
                (exportReport["losses"] as? [[String: Any]])?.isEmpty ?? true,
                name
            )

            let update = HostwrightCLI.run(
                arguments: [
                    "plan-stack-update", "./current.yaml", "folder/../desired.yaml",
                    "--output", "json",
                ],
                environment: composeReadOnlyEnvironment(files: FileBox(files: [
                    "current.yaml": composeExportManifest,
                    "desired.yaml": invalid,
                ]))
            )
            XCTAssertEqual(update.exitCode, CLIExitCode.validation.rawValue, name)
            XCTAssertEqual(update.standardOutput, "", name)
            let updateObject = try jsonObject(update.standardError)
            XCTAssertEqual(updateObject["kind"] as? String, "composeUpdatePlan", name)
            XCTAssertEqual(updateObject["currentPath"] as? String, "current.yaml", name)
            XCTAssertEqual(updateObject["desiredPath"] as? String, "desired.yaml", name)
            XCTAssertEqual(updateObject["accepted"] as? Bool, false, name)
            XCTAssertEqual(updateObject["mutatesRuntime"] as? Bool, false, name)
            XCTAssertEqual((updateObject["changes"] as? [[String: Any]])?.count, 0, name)
        }
    }

    func testComposeBoundedReaderAcceptsExactLimitAndRejectsOversizedAndInvalidUTF8() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { directory in
            let validSuffix = "\n" + """
            version: 3
            project: boundary
            services:
              api:
                image: ghcr.io/example/api:1
                resources:
                  requests:
                    cpus: 1
                    memory: 512MiB
                  limits:
                    cpus: 1
                    memory: 512MiB
            """
            let exactText = String(
                repeating: "#",
                count: ManifestParser.maximumUTF8Bytes - validSuffix.utf8.count
            ) + validSuffix
            let exactURL = directory.appendingPathComponent("exact.yaml")
            let oversizedURL = directory.appendingPathComponent("oversized.yaml")
            let invalidUTF8URL = directory.appendingPathComponent("invalid.yaml")
            let unsafeURL = directory.appendingPathComponent("unsafe.yaml")
            try Data(exactText.utf8).write(to: exactURL)
            try Data(repeating: 0x61, count: ManifestParser.maximumUTF8Bytes + 1)
                .write(to: oversizedURL)
            try Data([0xFF, 0xFE, 0xFD]).write(to: invalidUTF8URL)
            try FileManager.default.createSymbolicLink(
                at: unsafeURL,
                withDestinationURL: exactURL
            )

            var environment = composeReadOnlyEnvironment(files: FileBox())
            environment.readTextFile = { _ in
                XCTFail("Compose commands must not invoke the unbounded reader.")
                throw CLIUsageError("unexpected unbounded read")
            }
            environment.readBoundedTextFile = { path, maximumBytes in
                try hostwrightReadBoundedUTF8TextFile(
                    path: path,
                    maximumBytes: maximumBytes
                )
            }

            let exact = HostwrightCLI.run(
                arguments: ["export-stack", exactURL.path, "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(exact.exitCode, CLIExitCode.success.rawValue)
            XCTAssertEqual(try jsonObject(exact.standardOutput)["succeeded"] as? Bool, true)

            let oversized = HostwrightCLI.run(
                arguments: ["export-stack", oversizedURL.path, "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(oversized.exitCode, CLIExitCode.validation.rawValue)
            let oversizedObject = try jsonObject(oversized.standardError)
            XCTAssertEqual(oversizedObject["kind"] as? String, "composeExport")
            XCTAssertEqual(oversizedObject["succeeded"] as? Bool, false)
            XCTAssertTrue(oversized.standardError.contains("1 MiB"))

            let invalidUTF8 = HostwrightCLI.run(
                arguments: ["export-stack", invalidUTF8URL.path, "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(invalidUTF8.exitCode, CLIExitCode.validation.rawValue)
            let invalidUTF8Object = try jsonObject(invalidUTF8.standardError)
            XCTAssertEqual(invalidUTF8Object["kind"] as? String, "composeExport")
            XCTAssertEqual(invalidUTF8Object["succeeded"] as? Bool, false)
            XCTAssertTrue(invalidUTF8.standardError.contains("valid UTF-8"))

            let unsafe = HostwrightCLI.run(
                arguments: ["export-stack", unsafeURL.path, "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(unsafe.exitCode, CLIExitCode.validation.rawValue)
            let unsafeObject = try jsonObject(unsafe.standardError)
            XCTAssertEqual(unsafeObject["kind"] as? String, "composeExport")
            XCTAssertEqual(unsafeObject["succeeded"] as? Bool, false)
            XCTAssertTrue(unsafe.standardError.contains("could not be read safely"))

            let exactUpdate = HostwrightCLI.run(
                arguments: [
                    "plan-stack-update", exactURL.path, exactURL.path, "--output", "json",
                ],
                environment: environment
            )
            XCTAssertEqual(exactUpdate.exitCode, CLIExitCode.success.rawValue)
            XCTAssertEqual(try jsonObject(exactUpdate.standardOutput)["accepted"] as? Bool, true)

            for (path, expectedText) in [
                (oversizedURL.path, "1 MiB"),
                (invalidUTF8URL.path, "valid UTF-8"),
                (unsafeURL.path, "could not be read safely"),
            ] {
                let update = HostwrightCLI.run(
                    arguments: [
                        "plan-stack-update", exactURL.path, path, "--output", "json",
                    ],
                    environment: environment
                )
                XCTAssertEqual(update.exitCode, CLIExitCode.validation.rawValue)
                let object = try jsonObject(update.standardError)
                XCTAssertEqual(object["kind"] as? String, "composeUpdatePlan")
                XCTAssertEqual(object["accepted"] as? Bool, false)
                XCTAssertTrue(update.standardError.contains(expectedText))
            }
        }
    }

    func testPlanStackUpdateTextJSONAndRejectedPlanRemainReadOnly() throws {
        let files = FileBox(files: [
            "current.yaml": composeExportManifest,
            "desired.yaml": composeDesiredManifest,
        ])
        let environment = composeReadOnlyEnvironment(files: files)
        let text = HostwrightCLI.run(
            arguments: ["plan-stack-update", "current.yaml", "desired.yaml"],
            environment: environment
        )
        let json = HostwrightCLI.run(
            arguments: [
                "plan-stack-update", "current.yaml", "desired.yaml", "--output", "json",
            ],
            environment: environment
        )

        XCTAssertEqual(text.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(text.standardError, "")
        XCTAssertTrue(text.standardOutput.contains("Accepted: true"))
        XCTAssertTrue(text.standardOutput.contains("Mutates runtime: false"))
        XCTAssertTrue(text.standardOutput.contains("update-service api: image"))
        XCTAssertEqual(json.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(json.standardError, "")
        let object = try jsonObject(json.standardOutput)
        XCTAssertEqual(object["kind"] as? String, "composeUpdatePlan")
        XCTAssertEqual(object["currentPath"] as? String, "current.yaml")
        XCTAssertEqual(object["desiredPath"] as? String, "desired.yaml")
        XCTAssertEqual(object["accepted"] as? Bool, true)
        XCTAssertEqual(object["mutatesRuntime"] as? Bool, false)
        let changes = try XCTUnwrap(object["changes"] as? [[String: Any]])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?["kind"] as? String, "update-service")
        XCTAssertEqual(changes.first?["serviceName"] as? String, "api")
        XCTAssertEqual(changes.first?["fields"] as? [String], ["image"])
        XCTAssertEqual(files.readCounts, ["current.yaml": 2, "desired.yaml": 2])
        XCTAssertEqual(files.writeCount, 0)

        let rejectedFiles = FileBox(files: [
            "current.yaml": composeExportManifest,
            "desired.yaml": composeUnrepresentableManifest,
        ])
        let rejected = HostwrightCLI.run(
            arguments: [
                "plan-stack-update", "current.yaml", "desired.yaml", "--output", "json",
            ],
            environment: composeReadOnlyEnvironment(files: rejectedFiles)
        )

        XCTAssertEqual(rejected.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(rejected.standardOutput, "")
        let rejectedObject = try jsonObject(rejected.standardError)
        XCTAssertEqual(rejectedObject["accepted"] as? Bool, false)
        XCTAssertEqual(rejectedObject["mutatesRuntime"] as? Bool, false)
        XCTAssertEqual((rejectedObject["changes"] as? [[String: Any]])?.count, 0)
        let rejectedReport = try XCTUnwrap(rejectedObject["lossReport"] as? [String: Any])
        let rejectedLosses = try XCTUnwrap(rejectedReport["losses"] as? [[String: Any]])
        XCTAssertEqual(rejectedLosses.map { $0["code"] as? String }, ["HW-COMPOSE-003"])
        XCTAssertEqual(rejectedLosses.map { $0["path"] as? String }, ["$.desired.imagePolicy"])
        XCTAssertEqual(rejectedFiles.readCounts, ["current.yaml": 1, "desired.yaml": 1])
        XCTAssertEqual(rejectedFiles.writeCount, 0)
    }

    func testPlanStackUpdateReadsSameAndDotAliasInputIdentityOnlyOnce() throws {
        for paths in [
            ["manifest.yaml", "manifest.yaml"],
            ["manifest.yaml", "./manifest.yaml"],
        ] {
            let files = FileBox()
            var environment = composeReadOnlyEnvironment(files: files)
            let readSnapshot: (String) throws -> String = { path in
                XCTAssertTrue(paths.contains(path))
                files.readCounts["canonical-manifest", default: 0] += 1
                return files.readCounts["canonical-manifest"] == 1
                    ? self.composeExportManifest
                    : self.composeDesiredManifest.replacingOccurrences(
                        of: "project: compose-cli",
                        with: "project: swapped-after-first-read"
                    )
            }
            environment.readTextFile = readSnapshot
            environment.readBoundedTextFile = { path, _ in
                try readSnapshot(path)
            }

            let result = HostwrightCLI.run(
                arguments: [
                    "plan-stack-update", paths[0], paths[1], "--output", "json",
                ],
                environment: environment
            )

            let caseDescription = paths.joined(separator: ", ")
            XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue, caseDescription)
            XCTAssertEqual(files.readCounts["canonical-manifest"], 1, caseDescription)
            XCTAssertEqual(files.writeCount, 0, caseDescription)
            let object = try jsonObject(result.standardOutput)
            XCTAssertEqual(object["currentPath"] as? String, "manifest.yaml")
            XCTAssertEqual(object["desiredPath"] as? String, "manifest.yaml")
            XCTAssertEqual(object["accepted"] as? Bool, true)
            XCTAssertEqual((object["changes"] as? [[String: Any]])?.count, 0)
        }
    }
}
