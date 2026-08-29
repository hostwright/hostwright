import Foundation
import XCTest
@testable import HostwrightDesktopModel

@MainActor
final class DesktopActionCatalogTests: XCTestCase {
    func testCatalogMatchesTheFrozenPhase09InventoryAndCheckedInContract() throws {
        struct InventoryEntry: Decodable {
            let command: String
            let transport: String
        }

        let inventoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("contracts/v0.0.2/phase09-cli-parity-inventory.json")
        let inventory = try JSONDecoder().decode(
            [InventoryEntry].self,
            from: Data(contentsOf: inventoryURL)
        )
        let catalogInventory = DesktopActionCatalog.cliActions.map {
            (command: $0.command, transport: $0.transport.rawValue)
        }

        XCTAssertEqual(
            catalogInventory.map { "\($0.command)|\($0.transport)" },
            inventory.map { "\($0.command)|\($0.transport)" }
        )
        XCTAssertEqual(
            DesktopActionCatalog.cliActions.count,
            Set(DesktopActionCatalog.cliActions.map(\.command)).count
        )
        XCTAssertEqual(
            DesktopActionCatalog.guiElements.count,
            Set(DesktopActionCatalog.guiElements.map(\.identifier)).count
        )
        XCTAssertEqual(
            DesktopActionCatalog.guiActions.count,
            Set(DesktopActionCatalog.guiActions.map(\.identifier)).count
        )
        XCTAssertEqual(DesktopActionCatalog.contractVersion, 1)
        XCTAssertEqual(DesktopActionCatalog.controlProtocolRevision, "2.1")
        XCTAssertEqual(
            DesktopActionCatalog.parityStatus,
            .phase09PromotionRequired
        )

        let document = DesktopActionCatalog.document
        let firstEncoding = try DesktopActionCatalog.encodedDocument()
        let secondEncoding = try DesktopActionCatalogWireContract.encode(document)
        let fixture = try contractData()
        XCTAssertEqual(firstEncoding, secondEncoding)
        XCTAssertEqual(firstEncoding, fixture)

        let decoded = try DesktopActionCatalogWireContract.decode(fixture)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(try DesktopActionCatalogWireContract.encode(decoded), fixture)
    }

    func testStrictContractRejectsMalformedAndStructuralDrift() throws {
        let canonical = try contractData()
        let text = String(decoding: canonical, as: UTF8.self)
        let duplicate = Data(
            ("{\"\\u0063ontractVersion\":1," + String(text.dropFirst())).utf8
        )
        assertContractRejected(duplicate, as: .duplicateField)

        var object = try contractJSONObject(canonical)
        object["unexpected"] = "not-part-of-the-frozen-contract"
        assertContractRejected(try encodedJSONObject(object), as: .unknownField)

        object.removeValue(forKey: "unexpected")
        object.removeValue(forKey: "parityStatus")
        assertContractRejected(try encodedJSONObject(object), as: .missingField)

        object["parityStatus"] = DesktopActionCatalog.parityStatus.rawValue
        object["contractVersion"] = "1"
        assertContractRejected(try encodedJSONObject(object), as: .schemaDrift)

        var malformed = canonical
        malformed.append(contentsOf: Data(" trailing-content".utf8))
        assertContractRejected(malformed, as: .malformedJSON)
        assertContractRejected(Data(), as: .emptyOrOversizedDocument)
    }

    func testContractEncoderAndDecoderRejectSourceValueDrift() throws {
        let driftedDocument = DesktopActionCatalogDocument(
            contractVersion: DesktopActionCatalog.contractVersion + 1,
            controlProtocolRevision: DesktopActionCatalog.controlProtocolRevision,
            sourceCLIInventory: DesktopActionCatalog.sourceCLIInventory,
            parityStatus: DesktopActionCatalog.parityStatus,
            cliActions: DesktopActionCatalog.cliActions,
            guiElements: DesktopActionCatalog.guiElements,
            guiActions: DesktopActionCatalog.guiActions
        )
        XCTAssertThrowsError(try DesktopActionCatalogWireContract.encode(driftedDocument)) {
            XCTAssertEqual($0 as? DesktopActionCatalogContractError, .valueDrift)
        }

        var object = try contractJSONObject(try contractData())
        object["controlProtocolRevision"] = "not-the-frozen-revision"
        assertContractRejected(try encodedJSONObject(object), as: .valueDrift)

        var cliActions = try XCTUnwrap(object["cliActions"] as? [[String: Any]])
        cliActions.append(cliActions[0])
        object["controlProtocolRevision"] = DesktopActionCatalog.controlProtocolRevision
        object["cliActions"] = cliActions
        assertContractRejected(try encodedJSONObject(object), as: .valueDrift)
    }

    func testCatalogUsesTheCurrentAccessibilitySurfaceAndMapsOnlyKnownCommands() {
        let expectedElements = [
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
        XCTAssertEqual(
            Set(DesktopActionCatalog.guiElements.map(\.identifier)),
            Set(expectedElements)
        )

        let expectedActions = [
            DesktopAccessibilityIdentifier.workspaceOverview,
            DesktopAccessibilityIdentifier.workspaceEvents,
            DesktopAccessibilityIdentifier.workspaceLogs,
            DesktopAccessibilityIdentifier.reconnect,
            DesktopAccessibilityIdentifier.disconnect,
            DesktopAccessibilityIdentifier.statusRefresh,
            DesktopAccessibilityIdentifier.eventsRefresh,
            DesktopAccessibilityIdentifier.eventsCancel,
            DesktopAccessibilityIdentifier.selectedLogsOpen,
            DesktopAccessibilityIdentifier.logsCancel,
            DesktopAccessibilityIdentifier.menuReconnect,
            DesktopAccessibilityIdentifier.menuOpenWindow,
            DesktopAccessibilityIdentifier.menuQuit,
        ]
        XCTAssertEqual(
            Set(DesktopActionCatalog.guiActions.map(\.identifier)),
            Set(expectedActions)
        )
        XCTAssertTrue(
            DesktopActionCatalog.guiActions.allSatisfy {
                DesktopActionCatalog.guiElement(identifier: $0.identifier) != nil
            }
        )
        XCTAssertTrue(
            DesktopActionCatalog.guiActions.compactMap(\.command).allSatisfy {
                DesktopActionCatalog.cliAction(command: $0) != nil
            }
        )
        XCTAssertTrue(
            DesktopActionCatalog.guiActions.compactMap { action in
                action.command.flatMap { command in
                    DesktopActionCatalog.cliAction(command: command).map {
                        action.confirmationReview == $0.confirmationReview
                    }
                }
            }.allSatisfy { $0 }
        )
        XCTAssertTrue(
            DesktopActionCatalog.guiElements.compactMap(\.command).allSatisfy {
                DesktopActionCatalog.cliAction(command: $0) != nil
            }
        )
        for cliAction in DesktopActionCatalog.cliActions {
            let elementIdentifiers = Set(
                DesktopActionCatalog.guiElements
                    .filter { $0.command == cliAction.command }
                    .map(\.identifier)
            )
            XCTAssertEqual(
                Set(cliAction.guiElementIdentifiers),
                elementIdentifiers,
                cliAction.command
            )
        }
    }

    func testUnexposedAndMutatingInventoryActionsFailClosedWithReviewBoundaries() throws {
        let model = DesktopOperationsModel.live(
            homeDirectory: "/Users/tester",
            environment: [:]
        )

        let mutation = try XCTUnwrap(DesktopActionCatalog.cliAction(command: "apply"))
        XCTAssertEqual(mutation.mutability, .requiresReview)
        XCTAssertEqual(mutation.confirmationReview.state, .required)
        XCTAssertEqual(model.confirmationReview(forCommand: "apply"), mutation.confirmationReview)
        XCTAssertEqual(
            mutation.confirmationReview.reasonCode,
            DesktopActionConfirmationReview.phase09ReviewReasonCode
        )

        let bootstrap = try XCTUnwrap(
            DesktopActionCatalog.cliAction(command: "daemon.install")
        )
        XCTAssertEqual(bootstrap.transport, .bootstrapAPI)
        XCTAssertEqual(bootstrap.confirmationReview.state, .required)

        let readOnly = try XCTUnwrap(
            DesktopActionCatalog.cliAction(command: "status")
        )
        XCTAssertEqual(readOnly.mutability, .readOnly)
        XCTAssertEqual(readOnly.confirmationReview.state, .notRequired)

        let daemonStatus = DesktopActionCatalog.availability(
            forCommand: "daemon.status",
            model: model
        )
        XCTAssertEqual(daemonStatus.state, .unavailable)
        XCTAssertEqual(daemonStatus.reason, .disconnected)

        let unavailable = DesktopActionCatalog.availability(
            forCommand: "apply",
            model: model
        )
        XCTAssertEqual(unavailable.state, .blocked)
        XCTAssertEqual(unavailable.reason, .phase09PromotionRequired)

        let localOnly = DesktopActionCatalog.availability(
            forCommand: "help",
            model: model
        )
        XCTAssertEqual(localOnly.state, .blocked)
        XCTAssertEqual(localOnly.reason, .notExposed)

        let daemonHealth = DesktopActionCatalog.availability(
            forCommand: "daemon.status",
            model: model
        )
        XCTAssertEqual(daemonHealth.state, .unavailable)
        XCTAssertEqual(daemonHealth.reason, .disconnected)

        let hiddenReadOnly = DesktopActionCatalog.availability(
            forCommand: "daemon.validate",
            model: model
        )
        XCTAssertEqual(hiddenReadOnly.state, .blocked)
        XCTAssertEqual(hiddenReadOnly.reason, .notExposed)

        let unknown = DesktopActionCatalog.availability(
            forCommand: "not-in-the-frozen-inventory",
            model: model
        )
        XCTAssertEqual(unknown.state, .blocked)
        XCTAssertEqual(unknown.reason, .unknownAction)

        for action in DesktopActionCatalog.cliActions where action.mutability == .requiresReview {
            XCTAssertEqual(action.confirmationReview, .phase09Review, action.command)
            XCTAssertTrue(action.guiElementIdentifiers.isEmpty, action.command)
            XCTAssertFalse(
                DesktopActionCatalog.guiActions.contains { $0.command == action.command },
                action.command
            )
        }
    }

    func testAmbiguousInventoryCommandsRequireReviewAndDynamicLogElementsRemainKnown() throws {
        let model = DesktopOperationsModel.live(
            homeDirectory: "/Users/tester",
            environment: ["HOSTWRIGHT_APPLICATION_SUPPORT_DIR": "relative"]
        )

        for command in ["metrics", "traces"] {
            let action = try XCTUnwrap(DesktopActionCatalog.cliAction(command: command))
            XCTAssertEqual(action.mutability, .requiresReview, command)
            XCTAssertEqual(
                action.confirmationReview.state,
                .required,
                command
            )
            XCTAssertEqual(
                DesktopActionCatalog.availability(forCommand: command, model: model).reason,
                .phase09PromotionRequired,
                command
            )
        }

        let dynamicIdentifier = DesktopAccessibilityIdentifier.logsOpen(for: "web")
        let element = try XCTUnwrap(
            DesktopActionCatalog.guiElement(identifier: dynamicIdentifier)
        )
        XCTAssertEqual(element.role, .action)
        XCTAssertEqual(element.command, "logs")
        let action = try XCTUnwrap(
            DesktopActionCatalog.guiAction(identifier: dynamicIdentifier)
        )
        XCTAssertEqual(action.kind, .logStream)
        XCTAssertEqual(
            DesktopActionCatalog.confirmationReview(for: dynamicIdentifier).state,
            .notRequired
        )

        let failure = DesktopActionFailureContract.redact(
            actionIdentifier: dynamicIdentifier,
            error: DesktopControlFailure(
                code: "logs.unavailable",
                message: "secret-value"
            )
        )
        XCTAssertEqual(failure.actionIdentifier, dynamicIdentifier)
        XCTAssertEqual(failure.message, "The log stream is unavailable.")
    }

    func testFailureContractRedactsMessagesCodesAndUnknownActionIdentifiers() {
        let failure = DesktopActionFailureContract.redact(
            actionIdentifier: DesktopAccessibilityIdentifier.statusRefresh,
            error: DesktopControlFailure(
                code: "transport.connectionFailed",
                message: "token=secret-value /Users/tester/private-control.sock"
            )
        )
        XCTAssertEqual(failure.schemaVersion, 1)
        XCTAssertEqual(failure.actionIdentifier, DesktopAccessibilityIdentifier.statusRefresh)
        XCTAssertEqual(failure.code, "transport.connectionFailed")
        XCTAssertEqual(failure.message, "The local control endpoint is unavailable.")
        XCTAssertFalse(failure.message.contains("secret-value"))
        XCTAssertFalse(failure.message.contains("private-control.sock"))

        let unsafe = DesktopActionFailureContract.redact(
            actionIdentifier: "desktop.action?token=secret",
            error: DesktopControlFailure(
                code: "token=secret-value\n",
                message: "password=another-secret"
            )
        )
        XCTAssertEqual(unsafe.actionIdentifier, "desktop.action.unknown")
        XCTAssertEqual(unsafe.code, "desktop.action.failed")
        XCTAssertEqual(unsafe.message, "The desktop control action failed.")
        XCTAssertFalse(unsafe.message.contains("another-secret"))

        let arbitraryCode = DesktopActionFailureContract.redact(
            actionIdentifier: DesktopAccessibilityIdentifier.statusRefresh,
            error: DesktopControlFailure(code: "secret123", message: "hidden")
        )
        XCTAssertEqual(arbitraryCode.code, "desktop.action.failed")
    }

    private var contractURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                "contracts/v0.0.2/phase14-desktop-action-catalog-v1.json"
            )
    }

    private func contractData() throws -> Data {
        var data = try Data(contentsOf: contractURL)
        if data.last == 0x0A {
            data.removeLast()
        }
        return data
    }

    private func contractJSONObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encodedJSONObject(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func assertContractRejected(
        _ data: Data,
        as expected: DesktopActionCatalogContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DesktopActionCatalogWireContract.decode(data),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? DesktopActionCatalogContractError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
