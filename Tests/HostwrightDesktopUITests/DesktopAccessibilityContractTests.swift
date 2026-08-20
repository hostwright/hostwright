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

    func testEmptyCollectionsUseAnExplicitEmptyStateContract() {
        XCTAssertEqual(DesktopCollectionState(count: 0), .empty)
        XCTAssertEqual(DesktopCollectionState(count: 1), .populated)
        XCTAssertEqual(DesktopCollectionState(count: 500), .populated)
    }

    func testSceneRestorationKeysAndOfflineControlsRemainStable() {
        XCTAssertEqual(DesktopSceneStorageKey.selection, "desktop.console.selection")
        XCTAssertEqual(
            DesktopSceneStorageKey.selectedProject,
            "desktop.console.selectedProject"
        )
        XCTAssertEqual(
            DesktopSceneStorageKey.selectedService,
            "desktop.console.selectedService"
        )

        let identifiers = [
            DesktopAccessibilityIdentifier.connectionState,
            DesktopAccessibilityIdentifier.reconnect,
            DesktopAccessibilityIdentifier.disconnect,
            DesktopAccessibilityIdentifier.statusRefresh,
            DesktopAccessibilityIdentifier.overview,
            DesktopAccessibilityIdentifier.events,
            DesktopAccessibilityIdentifier.eventsRefresh,
            DesktopAccessibilityIdentifier.eventsCancel,
            DesktopAccessibilityIdentifier.logs,
            DesktopAccessibilityIdentifier.selectedLogsOpen,
            DesktopAccessibilityIdentifier.logsCancel,
            DesktopAccessibilityIdentifier.menuConnectionState,
            DesktopAccessibilityIdentifier.menuReconnect,
            DesktopAccessibilityIdentifier.menuOpenWindow,
        ]
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("desktop.") })
    }
}
