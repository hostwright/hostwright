import XCTest
@testable import HostwrightCore
@testable import HostwrightHealth

final class HostwrightHealthTests: XCTestCase {
    func testCompatibilityChecksReportUnsupportedPlatform() {
        let checks = DoctorScaffold.compatibilityChecks(
            for: PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(checks.count, 2)
        XCTAssertTrue(DoctorReport(checks: checks).hasFailures)
        XCTAssertEqual(checks.map(\.identifier), [.appleSilicon, .macOSVersion])
    }

    func testDoctorReportsMissingAppleContainerAsWarning() {
        let report = HostwrightDoctor.report(
            inputs: DoctorInputs(
                operatingSystemDescription: "macOS 26.5",
                platform: PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64"),
                swiftVersion: "Swift 6.3.2",
                containerExecutablePath: nil,
                manifestExists: false
            )
        )

        XCTAssertTrue(report.checks.contains { $0.identifier == .appleContainerCLI && $0.status == .warning })
        XCTAssertFalse(report.hasFailures)
    }
}
