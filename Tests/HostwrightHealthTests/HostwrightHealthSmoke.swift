import HostwrightCore
import HostwrightHealth

let hostwrightHealthSmoke: Void = {
    let checks = DoctorScaffold.compatibilityChecks(
        for: PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
    )

    precondition(checks.count == 2)
    precondition(DoctorReport(checks: checks).hasFailures)

    let report = HostwrightDoctor.report(
        inputs: DoctorInputs(
            operatingSystemDescription: "macOS 26.5",
            platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
            swiftVersion: "Swift 6.3.2",
            containerExecutablePath: nil,
            manifestExists: false
        )
    )

    precondition(report.checks.contains { $0.identifier == .appleContainerCLI && $0.status == .warning })
}()
