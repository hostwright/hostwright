import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore

final class HostwrightCLITests: XCTestCase {
    func testCommandParserRecognizesSupportedCommands() throws {
        XCTAssertEqual(try CLICommand.parse(arguments: ["--version"]), .version)
        XCTAssertEqual(try CLICommand.parse(arguments: ["init"]), .initManifest)
        XCTAssertEqual(try CLICommand.parse(arguments: ["validate"]), .validate(path: "hostwright.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["validate", "custom.yaml"]), .validate(path: "custom.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["plan"]), .plan(path: "hostwright.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["status"]), .status(path: "hostwright.yaml"))
        XCTAssertEqual(try CLICommand.parse(arguments: ["doctor"]), .doctor)
    }

    func testVersionOutput() {
        let result = HostwrightCLI.run(arguments: ["--version"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "0.0.0-dev\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testInitCreatesStarterManifestWithoutOverwriting() {
        let initFiles = FileBox()
        let initResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: initFiles))

        XCTAssertEqual(initResult.exitCode, 0)
        XCTAssertTrue(initFiles.files[HostwrightIdentity.manifestFileName]?.contains("project: api-local") == true)

        let existingFiles = FileBox(files: [HostwrightIdentity.manifestFileName: "project: existing\nservices:\n"])
        let overwriteResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: existingFiles))

        XCTAssertEqual(overwriteResult.exitCode, 1)
        XCTAssertTrue(overwriteResult.standardError.contains("HW-CLI-002"))
        XCTAssertEqual(existingFiles.files[HostwrightIdentity.manifestFileName], "project: existing\nservices:\n")
    }

    func testValidatePlanAndStatusAreNonMutating() {
        let validFiles = FileBox(files: [HostwrightIdentity.manifestFileName: HostwrightCLI.starterManifest])

        let validateResult = HostwrightCLI.run(arguments: ["validate"], environment: environment(files: validFiles))
        XCTAssertEqual(validateResult.exitCode, 0)
        XCTAssertTrue(validateResult.standardOutput.contains("Valid hostwright manifest"))

        let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: validFiles))
        XCTAssertEqual(planResult.exitCode, 0)
        XCTAssertTrue(planResult.standardOutput.contains("non-mutating"))
        XCTAssertTrue(planResult.standardOutput.contains("Runtime observation"))
        XCTAssertTrue(planResult.standardOutput.contains("Plan hash"))
        XCTAssertTrue(planResult.standardOutput.contains("Execution: unavailable until Phase 8"))
        XCTAssertTrue(planResult.standardOutput.contains("No runtime actions were executed"))

        let statusResult = HostwrightCLI.run(arguments: ["status"], environment: environment(files: validFiles))
        XCTAssertEqual(statusResult.exitCode, 0)
        XCTAssertTrue(statusResult.standardOutput.contains("Manifest: hostwright.yaml valid"))
        XCTAssertTrue(statusResult.standardOutput.contains("Runtime: unavailable"))
        XCTAssertFalse(statusResult.standardOutput.contains("running"))
        XCTAssertFalse(statusResult.standardOutput.contains("stopped"))
    }

    func testPlanOutputRedactsSecretLikeEnvironmentValues() {
        let files = FileBox(
            files: [
                HostwrightIdentity.manifestFileName: """
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    env:
                      API_TOKEN: token=super-secret

                """
            ]
        )

        let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: files))

        XCTAssertEqual(planResult.exitCode, 0)
        XCTAssertTrue(planResult.standardOutput.contains("secretRedacted"))
        XCTAssertTrue(planResult.standardOutput.contains("API_TOKEN"))
        XCTAssertFalse(planResult.standardOutput.contains("super-secret"))
    }

    func testDoctorReportsMissingAppleContainerAsWarning() {
        let result = HostwrightCLI.run(arguments: ["doctor"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("[warning] appleContainerCLI"))
    }

    private final class FileBox {
        var files: [String: String]

        init(files: [String: String] = [:]) {
            self.files = files
        }
    }

    private func environment(files: FileBox, containerPath: String? = nil) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { files.files[$0] != nil },
            readTextFile: { path in
                guard let text = files.files[path] else {
                    throw CLIUsageError("missing file")
                }
                return text
            },
            writeTextFile: { path, text in
                files.files[path] = text
            },
            executablePath: { name in name == "container" ? containerPath : "/usr/bin/\(name)" },
            swiftVersion: { "Swift 6.3.2" },
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS 26.5" }
        )
    }
}
