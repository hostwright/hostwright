import XCTest
@testable import HostwrightCore

final class HostwrightCoreTests: XCTestCase {
    func testHostwrightIdentityConstants() {
        XCTAssertEqual(HostwrightIdentity.projectName, "Hostwright")
        XCTAssertEqual(HostwrightIdentity.cliName, "hostwright")
        XCTAssertEqual(HostwrightIdentity.daemonName, "hostwrightd")
        XCTAssertEqual(HostwrightIdentity.manifestFileName, "hostwright.yaml")
        XCTAssertEqual(HostwrightIdentity.domain, "hostwright.dev")
        XCTAssertEqual(HostwrightIdentity.developmentVersion, "0.0.0-dev")
    }

    func testCompatibilityGateRejectsUnsupportedPlatform() {
        let diagnostics = CompatibilityGate.evaluate(
            PlatformSnapshot(macOSMajorVersion: 25, architecture: "x86_64")
        )

        XCTAssertEqual(diagnostics.map(\.code), [.unsupportedArchitecture, .unsupportedMacOSVersion])
    }
}
