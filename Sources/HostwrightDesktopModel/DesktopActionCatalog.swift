import Foundation
import HostwrightCommandTransport

public enum DesktopActionCatalogParityStatus: String, Codable, Equatable, Sendable {
    case phase09PromotionRequired = "phase09-promotion-required"
}

public enum DesktopActionMutability: String, Codable, Equatable, Sendable {
    case readOnly = "read-only"
    case requiresReview = "requires-review"
}

public enum DesktopActionReviewState: String, Codable, Equatable, Sendable {
    case notRequired = "not-required"
    case required
    case blocked
}

public struct DesktopActionConfirmationReview: Codable, Equatable, Sendable {
    public static let notRequiredReasonCode = "desktop.confirmation.notRequired"
    public static let phase09ReviewReasonCode = "desktop.confirmation.phase09ReviewRequired"
    public static let notExposedReasonCode = "desktop.action.notExposed"

    public let state: DesktopActionReviewState
    public let reasonCode: String
    public let message: String

    public init(
        state: DesktopActionReviewState,
        reasonCode: String,
        message: String
    ) {
        self.state = state
        self.reasonCode = reasonCode
        self.message = message
    }

    public static let notRequired = Self(
        state: .notRequired,
        reasonCode: notRequiredReasonCode,
        message: "This read-only desktop action does not change Hostwright state."
    )

    public static let phase09Review = Self(
        state: .required,
        reasonCode: phase09ReviewReasonCode,
        message: "Review authorization and the exact Control API operation after Phase 09 promotion."
    )

    public static let notExposed = Self(
        state: .blocked,
        reasonCode: notExposedReasonCode,
        message: "This operation is not exposed by the desktop console."
    )
}

public enum DesktopActionAvailabilityState: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case blocked
}

public enum DesktopActionAvailabilityReason: String, Codable, Equatable, Sendable {
    case ready
    case disconnected
    case connecting
    case reconnecting
    case controlEndpointUnavailable = "control-endpoint-unavailable"
    case requiresProject = "requires-project"
    case requiresService = "requires-service"
    case requiresObservedResource = "requires-observed-resource"
    case streamNotRunning = "stream-not-running"
    case notExposed = "not-exposed"
    case phase09PromotionRequired = "phase09-promotion-required"
    case unknownAction = "unknown-action"
}

public struct DesktopActionAvailability: Codable, Equatable, Sendable {
    public let identifier: String
    public let state: DesktopActionAvailabilityState
    public let reason: DesktopActionAvailabilityReason
    public let message: String

    public init(
        identifier: String,
        state: DesktopActionAvailabilityState,
        reason: DesktopActionAvailabilityReason,
        message: String
    ) {
        self.identifier = identifier
        self.state = state
        self.reason = reason
        self.message = message
    }
}

public struct DesktopActionAvailabilityContext: Equatable, Sendable {
    public let projectID: String?
    public let serviceID: String?

    public init(projectID: String? = nil, serviceID: String? = nil) {
        self.projectID = projectID
        self.serviceID = serviceID
    }
}

public enum DesktopGUIElementRole: String, Codable, Equatable, Sendable {
    case action
    case navigation
    case status
    case region
    case emptyState = "empty-state"
}

public enum DesktopGUIActionKind: String, Codable, Equatable, Sendable {
    case session
    case navigation
    case statusRequest = "status-request"
    case eventStream = "event-stream"
    case logStream = "log-stream"
    case streamCancellation = "stream-cancellation"
    case window
    case application
}

public struct DesktopCLIActionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let command: String
    public let transport: CLIControlTransportKind
    public let mutability: DesktopActionMutability
    public let confirmationReview: DesktopActionConfirmationReview
    public let guiElementIdentifiers: [String]

    public var id: String { command }

    public init(
        command: String,
        transport: CLIControlTransportKind,
        mutability: DesktopActionMutability,
        confirmationReview: DesktopActionConfirmationReview,
        guiElementIdentifiers: [String]
    ) {
        self.command = command
        self.transport = transport
        self.mutability = mutability
        self.confirmationReview = confirmationReview
        self.guiElementIdentifiers = guiElementIdentifiers
    }
}

public struct DesktopGUIElementDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let identifier: String
    public let role: DesktopGUIElementRole
    public let command: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        role: DesktopGUIElementRole,
        command: String?
    ) {
        self.identifier = identifier
        self.role = role
        self.command = command
    }
}

public struct DesktopGUIActionDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let identifier: String
    public let kind: DesktopGUIActionKind
    public let command: String?
    public let confirmationReview: DesktopActionConfirmationReview

    public var id: String { identifier }

    public init(
        identifier: String,
        kind: DesktopGUIActionKind,
        command: String?,
        confirmationReview: DesktopActionConfirmationReview
    ) {
        self.identifier = identifier
        self.kind = kind
        self.command = command
        self.confirmationReview = confirmationReview
    }
}

public struct DesktopActionCatalogDocument: Codable, Equatable, Sendable {
    public let contractVersion: Int
    public let controlProtocolRevision: String
    public let sourceCLIInventory: String
    public let parityStatus: DesktopActionCatalogParityStatus
    public let cliActions: [DesktopCLIActionDescriptor]
    public let guiElements: [DesktopGUIElementDescriptor]
    public let guiActions: [DesktopGUIActionDescriptor]

    public init(
        contractVersion: Int,
        controlProtocolRevision: String,
        sourceCLIInventory: String,
        parityStatus: DesktopActionCatalogParityStatus,
        cliActions: [DesktopCLIActionDescriptor],
        guiElements: [DesktopGUIElementDescriptor],
        guiActions: [DesktopGUIActionDescriptor]
    ) {
        self.contractVersion = contractVersion
        self.controlProtocolRevision = controlProtocolRevision
        self.sourceCLIInventory = sourceCLIInventory
        self.parityStatus = parityStatus
        self.cliActions = cliActions
        self.guiElements = guiElements
        self.guiActions = guiActions
    }
}

public enum DesktopActionCatalogContractError: Error, Equatable, Sendable {
    case emptyOrOversizedDocument
    case malformedJSON
    case duplicateField
    case unknownField
    case missingField
    case schemaDrift
    case valueDrift
}

public enum DesktopActionCatalogWireContract {
    public static let maximumDocumentBytes = 128 * 1_024

    public static func encode(_ document: DesktopActionCatalogDocument) throws -> Data {
        guard document == DesktopActionCatalog.document else {
            throw DesktopActionCatalogContractError.valueDrift
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> DesktopActionCatalogDocument {
        try DesktopActionCatalogStrictJSON.validate(data)
        let document: DesktopActionCatalogDocument
        do {
            document = try JSONDecoder().decode(DesktopActionCatalogDocument.self, from: data)
        } catch {
            throw DesktopActionCatalogContractError.schemaDrift
        }
        guard document == DesktopActionCatalog.document else {
            throw DesktopActionCatalogContractError.valueDrift
        }
        return document
    }
}

public struct DesktopActionFailure: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let actionIdentifier: String
    public let code: String
    public let message: String

    public init(
        schemaVersion: Int,
        actionIdentifier: String,
        code: String,
        message: String
    ) {
        self.schemaVersion = schemaVersion
        self.actionIdentifier = actionIdentifier
        self.code = code
        self.message = message
    }
}

public enum DesktopActionFailureContract {
    public static let schemaVersion = 1
    public static let fallbackCode = "desktop.action.failed"

    public static func redact(
        actionIdentifier: String,
        error: Error
    ) -> DesktopActionFailure {
        let safeActionIdentifier = DesktopActionCatalog.guiAction(identifier: actionIdentifier) == nil
            ? "desktop.action.unknown"
            : actionIdentifier
        let rawCode = (error as? DesktopControlFailure)?.code
        let code = safeCode(rawCode)
        return DesktopActionFailure(
            schemaVersion: schemaVersion,
            actionIdentifier: safeActionIdentifier,
            code: code,
            message: safeMessage(for: code)
        )
    }

    private static func safeCode(_ value: String?) -> String {
        guard let value,
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$",
                options: .regularExpression
            ) != nil,
            [
                "control.", "daemon.", "discovery.", "events.",
                "logs.", "status.", "transport.",
            ].contains(where: value.hasPrefix)
        else {
            return fallbackCode
        }
        return value
    }

    private static func safeMessage(for code: String) -> String {
        if code.hasPrefix("discovery.") || code.hasPrefix("transport.") {
            return "The local control endpoint is unavailable."
        }
        if code.hasPrefix("daemon.") {
            return "Daemon health is unavailable."
        }
        if code.hasPrefix("events.") {
            return "The event stream is unavailable."
        }
        if code.hasPrefix("logs.") {
            return "The log stream is unavailable."
        }
        if code.hasPrefix("status.") {
            return "Project status is unavailable."
        }
        return "The desktop control action failed."
    }
}

public enum DesktopActionCatalog {
    public static let contractVersion = 1
    public static let controlProtocolRevision = "2.1"
    public static let sourceCLIInventory =
        "contracts/v0.0.2/phase09-cli-parity-inventory.json"
    public static let parityStatus: DesktopActionCatalogParityStatus =
        .phase09PromotionRequired

    private static let knownReadOnlyCommands: Set<String> = [
        "version", "help", "capabilities", "observability", "runtime", "paths",
        "daemon.status", "daemon.validate", "migrate", "import-stack", "validate",
        "plan", "status", "inspect", "stats", "logs", "events", "diagnostics", "doctor",
    ]

    public static let cliActions: [DesktopCLIActionDescriptor] = [
        cli("version", .localPresentation),
        cli("help", .localPresentation),
        cli("capabilities", .persistentControlAPI),
        cli("observability", .persistentControlAPI),
        cli("runtime", .persistentControlAPI),
        cli("paths", .persistentControlAPI),
        cli("state", .persistentControlAPI),
        cli("secret", .persistentControlAPI),
        cli("registry", .persistentControlAPI),
        cli("image", .persistentControlAPI),
        cli("volume", .persistentControlAPI),
        cli("daemon.status", .persistentControlAPI, guiElements: [
            DesktopAccessibilityIdentifier.connectionState,
            DesktopAccessibilityIdentifier.menuConnectionState,
        ]),
        cli("daemon.install", .bootstrapAPI),
        cli("daemon.validate", .persistentControlAPI),
        cli("daemon.bootstrap", .persistentControlAPI),
        cli("daemon.start", .persistentControlAPI),
        cli("daemon.stop", .persistentControlAPI),
        cli("daemon.kickstart", .persistentControlAPI),
        cli("daemon.upgrade", .persistentControlAPI),
        cli("daemon.rollback", .persistentControlAPI),
        cli("daemon.disable", .persistentControlAPI),
        cli("daemon.repair", .bootstrapAPI),
        cli("daemon.uninstall", .bootstrapAPI),
        cli("restart-budget", .persistentControlAPI),
        cli("maintenance", .persistentControlAPI),
        cli("ownership", .persistentControlAPI),
        cli("metrics", .persistentControlAPI),
        cli("traces", .persistentControlAPI),
        cli("migrate", .persistentControlAPI),
        cli("init", .persistentControlAPI),
        cli("import-stack", .persistentControlAPI),
        cli("validate", .persistentControlAPI),
        cli("plan", .persistentControlAPI),
        cli("status", .persistentControlAPI, guiElements: [
            DesktopAccessibilityIdentifier.overview,
            DesktopAccessibilityIdentifier.statusRefresh,
        ]),
        cli("apply", .persistentControlAPI),
        cli("up", .persistentControlAPI),
        cli("down", .persistentControlAPI),
        cli("run", .persistentControlAPI),
        cli("start", .persistentControlAPI),
        cli("stop", .persistentControlAPI),
        cli("restart", .persistentControlAPI),
        cli("rm", .persistentControlAPI),
        cli("update", .persistentControlAPI),
        cli("exec", .persistentControlAPI),
        cli("attach", .persistentControlAPI),
        cli("copy", .persistentControlAPI),
        cli("export", .persistentControlAPI),
        cli("inspect", .persistentControlAPI),
        cli("stats", .persistentControlAPI),
        cli("logs", .persistentControlAPI, guiElements: [
            DesktopAccessibilityIdentifier.logs,
            DesktopAccessibilityIdentifier.selectedLogsOpen,
        ]),
        cli("events", .persistentControlAPI, guiElements: [
            DesktopAccessibilityIdentifier.events,
            DesktopAccessibilityIdentifier.eventsRefresh,
        ]),
        cli("recovery", .persistentControlAPI),
        cli("cleanup", .persistentControlAPI),
        cli("diagnostics", .persistentControlAPI),
        cli("benchmark", .persistentControlAPI),
        cli("extension", .persistentControlAPI),
        cli("doctor", .persistentControlAPI),
    ]

    public static let guiElements: [DesktopGUIElementDescriptor] = [
        element(DesktopAccessibilityIdentifier.connectionState, .status, command: "daemon.status"),
        element(DesktopAccessibilityIdentifier.reconnect, .action, command: nil),
        element(DesktopAccessibilityIdentifier.disconnect, .action, command: nil),
        element(DesktopAccessibilityIdentifier.statusRefresh, .action, command: "status"),
        element(DesktopAccessibilityIdentifier.workspaceOverview, .navigation, command: nil),
        element(DesktopAccessibilityIdentifier.workspaceEvents, .navigation, command: nil),
        element(DesktopAccessibilityIdentifier.workspaceLogs, .navigation, command: nil),
        element(DesktopAccessibilityIdentifier.overview, .region, command: "status"),
        element(DesktopAccessibilityIdentifier.emptyOverview, .emptyState, command: nil),
        element(DesktopAccessibilityIdentifier.emptyServices, .emptyState, command: nil),
        element(DesktopAccessibilityIdentifier.events, .region, command: "events"),
        element(DesktopAccessibilityIdentifier.emptyEvents, .emptyState, command: nil),
        element(DesktopAccessibilityIdentifier.eventsRefresh, .action, command: "events"),
        element(DesktopAccessibilityIdentifier.eventsCancel, .action, command: nil),
        element(DesktopAccessibilityIdentifier.logs, .region, command: "logs"),
        element(DesktopAccessibilityIdentifier.emptyLogs, .emptyState, command: nil),
        element(DesktopAccessibilityIdentifier.selectedLogsOpen, .action, command: "logs"),
        element(DesktopAccessibilityIdentifier.logsCancel, .action, command: nil),
        element(DesktopAccessibilityIdentifier.menuConnectionState, .status, command: "daemon.status"),
        element(DesktopAccessibilityIdentifier.menuReconnect, .action, command: nil),
        element(DesktopAccessibilityIdentifier.menuOpenWindow, .action, command: nil),
        element(DesktopAccessibilityIdentifier.menuQuit, .action, command: nil),
    ]

    public static let guiActions: [DesktopGUIActionDescriptor] = [
        gui(DesktopAccessibilityIdentifier.workspaceOverview, .navigation, command: nil),
        gui(DesktopAccessibilityIdentifier.workspaceEvents, .navigation, command: nil),
        gui(DesktopAccessibilityIdentifier.workspaceLogs, .navigation, command: nil),
        gui(DesktopAccessibilityIdentifier.reconnect, .session, command: nil),
        gui(DesktopAccessibilityIdentifier.disconnect, .session, command: nil),
        gui(DesktopAccessibilityIdentifier.statusRefresh, .statusRequest, command: "status"),
        gui(DesktopAccessibilityIdentifier.eventsRefresh, .eventStream, command: "events"),
        gui(DesktopAccessibilityIdentifier.eventsCancel, .streamCancellation, command: nil),
        gui(DesktopAccessibilityIdentifier.selectedLogsOpen, .logStream, command: "logs"),
        gui(DesktopAccessibilityIdentifier.logsCancel, .streamCancellation, command: nil),
        gui(DesktopAccessibilityIdentifier.menuReconnect, .session, command: nil),
        gui(DesktopAccessibilityIdentifier.menuOpenWindow, .window, command: nil),
        gui(DesktopAccessibilityIdentifier.menuQuit, .application, command: nil),
    ]

    public static var document: DesktopActionCatalogDocument {
        DesktopActionCatalogDocument(
            contractVersion: contractVersion,
            controlProtocolRevision: controlProtocolRevision,
            sourceCLIInventory: sourceCLIInventory,
            parityStatus: parityStatus,
            cliActions: cliActions,
            guiElements: guiElements,
            guiActions: guiActions
        )
    }

    public static func encodedDocument() throws -> Data {
        try DesktopActionCatalogWireContract.encode(document)
    }

    public static func cliAction(command: String) -> DesktopCLIActionDescriptor? {
        cliActions.first { $0.command == command }
    }

    public static func guiElement(identifier: String) -> DesktopGUIElementDescriptor? {
        if let element = guiElements.first(where: { $0.identifier == identifier }) {
            return element
        }
        guard identifier.hasPrefix(DesktopAccessibilityIdentifier.logsOpenPrefix),
            identifier.count > DesktopAccessibilityIdentifier.logsOpenPrefix.count else {
            return nil
        }
        return element(
            identifier,
            .action,
            command: "logs"
        )
    }

    public static func guiAction(identifier: String) -> DesktopGUIActionDescriptor? {
        if let action = guiActions.first(where: { $0.identifier == identifier }) {
            return action
        }
        guard identifier.hasPrefix(DesktopAccessibilityIdentifier.logsOpenPrefix),
            identifier.count > DesktopAccessibilityIdentifier.logsOpenPrefix.count else {
            return nil
        }
        return gui(
            identifier,
            .logStream,
            command: "logs"
        )
    }

    @MainActor
    public static func availability(
        for identifier: String,
        model: DesktopOperationsModel,
        context: DesktopActionAvailabilityContext = .init()
    ) -> DesktopActionAvailability {
        guard let action = guiAction(identifier: identifier) else {
            return blocked(
                identifier: identifier,
                reason: .unknownAction
            )
        }

        switch action.kind {
        case .navigation, .window, .application:
            return ready(identifier: identifier)
        case .session:
            if identifier == DesktopAccessibilityIdentifier.disconnect,
                case .disconnected = model.connectionState {
                return unavailable(identifier: identifier, reason: .disconnected)
            }
            return ready(identifier: identifier)
        case .statusRequest, .eventStream:
            return connectionAvailability(identifier: identifier, state: model.connectionState)
        case .streamCancellation:
            let running = identifier == DesktopAccessibilityIdentifier.eventsCancel
                ? model.isEventStreamRunning
                : model.isLogStreamRunning
            return running
                ? ready(identifier: identifier)
                : unavailable(identifier: identifier, reason: .streamNotRunning)
        case .logStream:
            guard case .connected = model.connectionState else {
                return connectionAvailability(identifier: identifier, state: model.connectionState)
            }
            guard let project = model.projects.first else {
                return unavailable(identifier: identifier, reason: .requiresProject)
            }
            if let projectID = context.projectID, projectID != project.id {
                return unavailable(identifier: identifier, reason: .requiresProject)
            }
            guard let serviceID = context.serviceID,
                let service = project.services.first(where: { $0.id == serviceID }) else {
                return unavailable(identifier: identifier, reason: .requiresService)
            }
            guard service.resourceIdentifier != nil else {
                return unavailable(identifier: identifier, reason: .requiresObservedResource)
            }
            return ready(identifier: identifier)
        }
    }

    @MainActor
    public static func availability(
        forCommand command: String,
        model: DesktopOperationsModel,
        context: DesktopActionAvailabilityContext = .init()
    ) -> DesktopActionAvailability {
        guard let action = cliAction(command: command) else {
            return blocked(identifier: command, reason: .unknownAction)
        }
        guard action.mutability == .readOnly else {
            return blocked(identifier: command, reason: .phase09PromotionRequired)
        }
        guard let guiAction = guiActions.first(where: { $0.command == command }) else {
            if guiElements.contains(where: {
                $0.command == command && $0.role == .status
            }) {
                return connectionAvailability(identifier: command, state: model.connectionState)
            }
            return blocked(identifier: command, reason: .notExposed)
        }
        return availability(for: guiAction.identifier, model: model, context: context)
    }

    public static func confirmationReview(for identifier: String) -> DesktopActionConfirmationReview {
        guiAction(identifier: identifier)?.confirmationReview ?? .notExposed
    }

    public static func confirmationReview(forCommand command: String) -> DesktopActionConfirmationReview {
        cliAction(command: command)?.confirmationReview ?? .notExposed
    }

    private static func cli(
        _ command: String,
        _ transport: CLIControlTransportKind,
        guiElements: [String] = []
    ) -> DesktopCLIActionDescriptor {
        let mutability: DesktopActionMutability = knownReadOnlyCommands.contains(command)
            ? .readOnly
            : .requiresReview
        return DesktopCLIActionDescriptor(
            command: command,
            transport: transport,
            mutability: mutability,
            confirmationReview: mutability == .readOnly
                ? .notRequired
                : .phase09Review,
            guiElementIdentifiers: guiElements
        )
    }

    private static func element(
        _ identifier: String,
        _ role: DesktopGUIElementRole,
        command: String?
    ) -> DesktopGUIElementDescriptor {
        DesktopGUIElementDescriptor(identifier: identifier, role: role, command: command)
    }

    private static func gui(
        _ identifier: String,
        _ kind: DesktopGUIActionKind,
        command: String?
    ) -> DesktopGUIActionDescriptor {
        let confirmationReview = command.flatMap { cliAction(command: $0)?.confirmationReview }
            ?? .notRequired
        return DesktopGUIActionDescriptor(
            identifier: identifier,
            kind: kind,
            command: command,
            confirmationReview: confirmationReview
        )
    }

    @MainActor
    private static func connectionAvailability(
        identifier: String,
        state: DesktopConnectionState
    ) -> DesktopActionAvailability {
        switch state {
        case .connected:
            return ready(identifier: identifier)
        case .disconnected:
            return unavailable(identifier: identifier, reason: .disconnected)
        case .connecting:
            return unavailable(identifier: identifier, reason: .connecting)
        case .reconnecting:
            return unavailable(identifier: identifier, reason: .reconnecting)
        case .unavailable:
            return unavailable(identifier: identifier, reason: .controlEndpointUnavailable)
        }
    }

    private static func ready(identifier: String) -> DesktopActionAvailability {
        DesktopActionAvailability(
            identifier: identifier,
            state: .available,
            reason: .ready,
            message: "Available."
        )
    }

    private static func unavailable(
        identifier: String,
        reason: DesktopActionAvailabilityReason
    ) -> DesktopActionAvailability {
        DesktopActionAvailability(
            identifier: identifier,
            state: .unavailable,
            reason: reason,
            message: message(for: reason)
        )
    }

    private static func blocked(
        identifier: String,
        reason: DesktopActionAvailabilityReason
    ) -> DesktopActionAvailability {
        DesktopActionAvailability(
            identifier: identifier,
            state: .blocked,
            reason: reason,
            message: message(for: reason)
        )
    }

    private static func message(for reason: DesktopActionAvailabilityReason) -> String {
        switch reason {
        case .ready:
            return "Available."
        case .disconnected:
            return "Connect to the local daemon before using this action."
        case .connecting:
            return "The desktop client is connecting to the local daemon."
        case .reconnecting:
            return "The desktop client is reconnecting to the local daemon."
        case .controlEndpointUnavailable:
            return "The local control endpoint is unavailable."
        case .requiresProject:
            return "A project status is required for this action."
        case .requiresService:
            return "Select an observed service before using this action."
        case .requiresObservedResource:
            return "The selected service has no observed runtime resource."
        case .streamNotRunning:
            return "No stream is active for this action."
        case .notExposed:
            return "This operation is not exposed by the desktop console."
        case .phase09PromotionRequired:
            return "Desktop execution awaits Phase 09 Control API promotion."
        case .unknownAction:
            return "This desktop action is not recognized."
        }
    }
}

@MainActor
public extension DesktopOperationsModel {
    func actionAvailability(
        for identifier: String,
        context: DesktopActionAvailabilityContext = .init()
    ) -> DesktopActionAvailability {
        DesktopActionCatalog.availability(for: identifier, model: self, context: context)
    }

    func actionAvailability(
        forCommand command: String,
        context: DesktopActionAvailabilityContext = .init()
    ) -> DesktopActionAvailability {
        DesktopActionCatalog.availability(forCommand: command, model: self, context: context)
    }

    func confirmationReview(for identifier: String) -> DesktopActionConfirmationReview {
        DesktopActionCatalog.confirmationReview(for: identifier)
    }

    func confirmationReview(forCommand command: String) -> DesktopActionConfirmationReview {
        DesktopActionCatalog.confirmationReview(forCommand: command)
    }

    func redactedActionFailure(
        for identifier: String,
        error: Error
    ) -> DesktopActionFailure {
        DesktopActionFailureContract.redact(actionIdentifier: identifier, error: error)
    }
}

private enum DesktopActionCatalogStrictJSON {
    private indirect enum ValueRule {
        case object(ObjectRule)
        case array(ValueRule)
        case string
        case integer
    }

    private struct ObjectRule {
        let allowedKeys: Set<String>
        let requiredKeys: Set<String>
        let valueRules: [String: ValueRule]
    }

    static func validate(_ data: Data) throws {
        guard !data.isEmpty,
            data.count <= DesktopActionCatalogWireContract.maximumDocumentBytes else {
            throw DesktopActionCatalogContractError.emptyOrOversizedDocument
        }
        var parser = Parser(bytes: Array(data))
        try parser.validateTopLevelObject(using: documentRule())
    }

    private static func documentRule() -> ObjectRule {
        let review = ObjectRule(
            allowedKeys: ["state", "reasonCode", "message"],
            requiredKeys: ["state", "reasonCode", "message"],
            valueRules: [
                "state": .string,
                "reasonCode": .string,
                "message": .string,
            ]
        )
        let cliAction = ObjectRule(
            allowedKeys: [
                "command", "transport", "mutability", "confirmationReview",
                "guiElementIdentifiers",
            ],
            requiredKeys: [
                "command", "transport", "mutability", "confirmationReview",
                "guiElementIdentifiers",
            ],
            valueRules: [
                "command": .string,
                "transport": .string,
                "mutability": .string,
                "confirmationReview": .object(review),
                "guiElementIdentifiers": .array(.string),
            ]
        )
        let guiElement = ObjectRule(
            allowedKeys: ["identifier", "role", "command"],
            requiredKeys: ["identifier", "role"],
            valueRules: [
                "identifier": .string,
                "role": .string,
                "command": .string,
            ]
        )
        let guiAction = ObjectRule(
            allowedKeys: ["identifier", "kind", "command", "confirmationReview"],
            requiredKeys: ["identifier", "kind", "confirmationReview"],
            valueRules: [
                "identifier": .string,
                "kind": .string,
                "command": .string,
                "confirmationReview": .object(review),
            ]
        )
        return ObjectRule(
            allowedKeys: [
                "contractVersion", "controlProtocolRevision", "sourceCLIInventory",
                "parityStatus", "cliActions", "guiElements", "guiActions",
            ],
            requiredKeys: [
                "contractVersion", "controlProtocolRevision", "sourceCLIInventory",
                "parityStatus", "cliActions", "guiElements", "guiActions",
            ],
            valueRules: [
                "contractVersion": .integer,
                "controlProtocolRevision": .string,
                "sourceCLIInventory": .string,
                "parityStatus": .string,
                "cliActions": .array(.object(cliAction)),
                "guiElements": .array(.object(guiElement)),
                "guiActions": .array(.object(guiAction)),
            ]
        )
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0

        mutating func validateTopLevelObject(using rule: ObjectRule) throws {
            try skipWhitespace()
            try parseObject(using: rule)
            try skipWhitespace()
            guard index == bytes.count else {
                throw DesktopActionCatalogContractError.malformedJSON
            }
        }

        mutating func parseValue(using rule: ValueRule) throws {
            switch rule {
            case .object(let objectRule):
                try parseObject(using: objectRule)
            case .array(let elementRule):
                try parseArray(of: elementRule)
            case .string:
                try skipWhitespace()
                guard peek() == 34 else {
                    throw DesktopActionCatalogContractError.schemaDrift
                }
                _ = try parseString()
            case .integer:
                try parseInteger()
            }
        }

        mutating func parseObject(using rule: ObjectRule) throws {
            try skipWhitespace()
            guard peek() == 123 else {
                throw DesktopActionCatalogContractError.schemaDrift
            }
            try enterContainer()
            defer { depth -= 1 }
            index += 1
            try skipWhitespace()
            var seen = Set<String>()
            if peek() == 125 {
                index += 1
            } else {
                while true {
                    let key = try parseString()
                    guard seen.insert(key).inserted else {
                        throw DesktopActionCatalogContractError.duplicateField
                    }
                    guard rule.allowedKeys.contains(key),
                        let valueRule = rule.valueRules[key] else {
                        throw DesktopActionCatalogContractError.unknownField
                    }
                    try skipWhitespace()
                    try require(58)
                    try parseValue(using: valueRule)
                    try skipWhitespace()
                    if peek() == 44 {
                        index += 1
                        try skipWhitespace()
                        continue
                    }
                    try require(125)
                    break
                }
            }
            guard rule.requiredKeys.isSubset(of: seen) else {
                throw DesktopActionCatalogContractError.missingField
            }
        }

        mutating func parseArray(of elementRule: ValueRule) throws {
            try skipWhitespace()
            guard peek() == 91 else {
                throw DesktopActionCatalogContractError.schemaDrift
            }
            try enterContainer()
            defer { depth -= 1 }
            index += 1
            try skipWhitespace()
            if peek() == 93 {
                index += 1
                return
            }
            while true {
                try parseValue(using: elementRule)
                try skipWhitespace()
                if peek() == 44 {
                    index += 1
                    try skipWhitespace()
                    continue
                }
                try require(93)
                return
            }
        }

        mutating func parseString() throws -> String {
            try skipWhitespace()
            try require(34)
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if escaped {
                    escaped = false
                } else if byte == 92 {
                    escaped = true
                } else if byte == 34 {
                    let data = Data(bytes[start...index])
                    index += 1
                    guard let value = try? JSONDecoder().decode(String.self, from: data) else {
                        throw DesktopActionCatalogContractError.malformedJSON
                    }
                    return value
                }
                index += 1
            }
            throw DesktopActionCatalogContractError.malformedJSON
        }

        mutating func parseInteger() throws {
            try skipWhitespace()
            if peek() == 45 {
                index += 1
            }
            guard let first = peek() else {
                throw DesktopActionCatalogContractError.schemaDrift
            }
            if first == 48 {
                index += 1
            } else if (49...57).contains(first) {
                index += 1
                while let byte = peek(), (48...57).contains(byte) {
                    index += 1
                }
            } else {
                throw DesktopActionCatalogContractError.schemaDrift
            }
        }

        mutating func enterContainer() throws {
            depth += 1
            guard depth <= 8 else {
                throw DesktopActionCatalogContractError.schemaDrift
            }
        }

        mutating func skipWhitespace() throws {
            while let byte = peek(), [9, 10, 13, 32].contains(byte) {
                index += 1
            }
        }

        mutating func require(_ expected: UInt8) throws {
            guard peek() == expected else {
                throw DesktopActionCatalogContractError.malformedJSON
            }
            index += 1
        }

        func peek() -> UInt8? {
            index < bytes.count ? bytes[index] : nil
        }
    }
}
