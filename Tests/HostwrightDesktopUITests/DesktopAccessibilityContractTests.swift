import Foundation
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
            DesktopAccessibilityIdentifier.workspaceOverview,
            DesktopAccessibilityIdentifier.workspaceEvents,
            DesktopAccessibilityIdentifier.workspaceLogs,
            DesktopAccessibilityIdentifier.overview,
            DesktopAccessibilityIdentifier.emptyOverview,
            DesktopAccessibilityIdentifier.emptyServices,
            DesktopAccessibilityIdentifier.events,
            DesktopAccessibilityIdentifier.emptyEvents,
            DesktopAccessibilityIdentifier.eventsRefresh,
            DesktopAccessibilityIdentifier.eventsCancel,
            DesktopAccessibilityIdentifier.logs,
            DesktopAccessibilityIdentifier.emptyLogs,
            DesktopAccessibilityIdentifier.selectedLogsOpen,
            DesktopAccessibilityIdentifier.logsCancel,
            DesktopAccessibilityIdentifier.menuConnectionState,
            DesktopAccessibilityIdentifier.menuReconnect,
            DesktopAccessibilityIdentifier.menuOpenWindow,
            DesktopAccessibilityIdentifier.menuQuit,
        ]
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
        XCTAssertTrue(identifiers.allSatisfy { $0.hasPrefix("desktop.") })
    }

    func testDynamicServiceLogIdentifiersAndCatalogBackedControlGatesRemainStable() throws {
        XCTAssertEqual(
            DesktopAccessibilityIdentifier.logsOpen(for: "web"),
            "desktop.logs.open.web"
        )

        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/HostwrightDesktopApp/OperationsConsoleView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        for expected in [
            "for: DesktopAccessibilityIdentifier.statusRefresh",
            "for: DesktopAccessibilityIdentifier.eventsRefresh",
            ".state != .available",
            "DesktopAccessibilityIdentifier.logsOpen(for: service.id)",
            "DesktopAccessibilityIdentifier.selectedLogsOpen",
            "model.cancelEventStream()",
            "model.cancelLogStream()"
        ] {
            XCTAssertTrue(source.contains(expected), "missing UI contract: \(expected)")
        }
        XCTAssertFalse(source.contains("model.cancelStreams()"))
    }
}
