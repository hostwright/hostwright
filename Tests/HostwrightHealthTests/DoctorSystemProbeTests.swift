import Foundation
import XCTest
@testable import HostwrightHealth

final class DoctorSystemProbeTests: XCTestCase {
    func testLiveProbeUsesPublicReadOnlyHostBoundaries() throws {
        let executable = try XCTUnwrap(CommandLine.arguments.first)

        let snapshot = DoctorSystemProbe.current(
            executablePath: executable,
            developmentBuild: true,
            containerExecutablePath: nil,
            swiftExecutablePath: "/usr/bin/swift"
        )

        XCTAssertTrue(snapshot.localNetwork.loopbackAvailable)
        XCTAssertFalse(snapshot.localNetwork.authorizationWasProbed)
        XCTAssertGreaterThan(snapshot.resourcePressure.physicalMemoryBytes, 0)
        XCTAssertNotEqual(snapshot.resourcePressure.thermalState, .unknown)
        XCTAssertTrue(snapshot.tools.contains { $0.identifier == "codesign" && $0.available })
        XCTAssertTrue(snapshot.tools.contains { $0.identifier == "gatekeeper-spctl" && $0.available })
        XCTAssertEqual(
            snapshot.tools.first { $0.identifier == "apple-container-cli" }?.available,
            false
        )
        XCTAssertNotEqual(snapshot.signingTrust.codeSignature, .unavailable)
        XCTAssertNotEqual(snapshot.signingTrust.gatekeeper, .unavailable)
    }
}
