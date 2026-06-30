import HostwrightCLI
import HostwrightCore

let hostwrightCLISmoke: Void = {
    final class FileBox {
        var files: [String: String]

        init(files: [String: String] = [:]) {
            self.files = files
        }
    }

    func environment(files: FileBox, containerPath: String? = nil) -> CLIEnvironment {
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

    let version = HostwrightCLI.run(arguments: ["--version"], environment: environment(files: FileBox()))
    precondition(version.standardOutput == "0.0.0-dev\n")

    let initFiles = FileBox()
    let initResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: initFiles))
    precondition(initResult.exitCode == 0)
    precondition(initFiles.files[HostwrightIdentity.manifestFileName]?.contains("project: api-local") == true)

    let existingFiles = FileBox(files: [HostwrightIdentity.manifestFileName: "project: existing\nservices:\n"])
    let overwriteResult = HostwrightCLI.run(arguments: ["init"], environment: environment(files: existingFiles))
    precondition(overwriteResult.exitCode == 1)
    precondition(overwriteResult.standardError.contains("HW-CLI-002"))

    let validFiles = FileBox(files: [HostwrightIdentity.manifestFileName: HostwrightCLI.starterManifest])
    let validateResult = HostwrightCLI.run(arguments: ["validate"], environment: environment(files: validFiles))
    precondition(validateResult.exitCode == 0)
    precondition(validateResult.standardOutput.contains("Valid hostwright manifest"))

    let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: validFiles))
    precondition(planResult.exitCode == 0)
    precondition(planResult.standardOutput.contains("non-mutating"))
    precondition(planResult.standardOutput.contains("Runtime observation"))
    precondition(planResult.standardOutput.contains("No runtime actions were executed"))

    let statusResult = HostwrightCLI.run(arguments: ["status"], environment: environment(files: validFiles))
    precondition(statusResult.exitCode == 0)
    precondition(statusResult.standardOutput.contains("Manifest: hostwright.yaml valid"))
    precondition(statusResult.standardOutput.contains("Runtime: unavailable"))
    precondition(!statusResult.standardOutput.contains("running"))
    precondition(!statusResult.standardOutput.contains("stopped"))

    let doctorResult = HostwrightCLI.run(arguments: ["doctor"], environment: environment(files: FileBox()))
    precondition(doctorResult.exitCode == 0)
    precondition(doctorResult.standardOutput.contains("[warning] appleContainerCLI"))
}()

