import XCTest
@testable import HostwrightDesktopModel

final class DesktopAccessibilityContractTests: XCTestCase {
    func testConnectionStatesHaveStableSpokenLabels() {
        XCTAssertEqual(DesktopConnectionState.disconnected.label, "Disconnected")
        XCTAssertEqual(DesktopConnectionState.connecting.label, "Connecting")
        XCTAssertEqual(DesktopConnectionState.connected.label, "Connected")
        XCTAssertEqual(
            DesktopConnectionState.reconnecting(attempt: 2, delayMilliseconds: 1000).label,
            "Reconnecting"
        )
        XCTAssertEqual(
            DesktopConnectionState.unavailable(
                DesktopControlFailure(code: "transport.connectionFailed", message: "Unavailable")
            ).label,
            "Unavailable"
        )
    }

    func testSemanticServiceStatesCarryAIconCueAlongsideText() {
        for availability in [
            DesktopServiceAvailability.healthy,
            .transitional,
            .failed,
            .absent,
            .unknown,
        ] {
            XCTAssertFalse(availability.label.isEmpty)
            XCTAssertFalse(availability.systemImage.isEmpty)
        }
    }
}
