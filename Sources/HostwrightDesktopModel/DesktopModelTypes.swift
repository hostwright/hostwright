import Foundation

public enum DesktopCollectionState: Equatable, Sendable {
    case empty
    case populated

    public init(count: Int) {
        self = count == 0 ? .empty : .populated
    }
}

public enum DesktopAccessibilityIdentifier {
    public static let connectionState = "desktop.connection.state"
    public static let reconnect = "desktop.connection.reconnect"
    public static let disconnect = "desktop.connection.disconnect"
    public static let statusRefresh = "desktop.status.refresh"
    public static let workspaceOverview = "desktop.workspace.overview"
    public static let workspaceEvents = "desktop.workspace.events"
    public static let workspaceLogs = "desktop.workspace.logs"
    public static let overview = "desktop.console.overview"
    public static let emptyOverview = "desktop.console.empty.overview"
    public static let emptyServices = "desktop.console.empty.services"
    public static let events = "desktop.console.events"
    public static let emptyEvents = "desktop.console.empty.events"
    public static let eventsRefresh = "desktop.events.refresh"
    public static let eventsCancel = "desktop.events.cancel"
    public static let logs = "desktop.console.logs"
    public static let emptyLogs = "desktop.console.empty.logs"
    public static let selectedLogsOpen = "desktop.logs.open.selected"
    public static let logsCancel = "desktop.logs.cancel"
    public static let menuConnectionState = "desktop.menu.connection.state"
    public static let menuReconnect = "desktop.menu.reconnect"
    public static let menuOpenWindow = "desktop.menu.openWindow"
    public static let menuQuit = "desktop.menu.quit"
}

public enum DesktopSceneStorageKey {
    public static let selection = "desktop.console.selection"
    public static let selectedProject = "desktop.console.selectedProject"
    public static let selectedService = "desktop.console.selectedService"
}

public struct DesktopControlFailure: Error, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "\(code): \(message)"
    }
}

public enum DesktopConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int, delayMilliseconds: UInt64)
    case unavailable(DesktopControlFailure)

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .unavailable: return "Unavailable"
        }
    }
}

public struct DesktopDaemonHealth: Equatable, Sendable {
    public let readiness: String
    public let reasonCode: String
    public let label: String
    public let domain: String
    public let generation: Int?
    public let processID: Int32?

    public init(
        readiness: String,
        reasonCode: String,
        label: String,
        domain: String,
        generation: Int?,
        processID: Int32?
    ) {
        self.readiness = readiness
        self.reasonCode = reasonCode
        self.label = label
        self.domain = domain
        self.generation = generation
        self.processID = processID
    }

    public var isServing: Bool {
        readiness == "running"
    }

    public var statusLabel: String {
        switch readiness {
        case "running": return "Running"
        case "stopped": return "Stopped"
        case "not-installed": return "Not installed"
        case "disabled": return "Disabled"
        case "recovery-required": return "Recovery required"
        default: return readiness.capitalized
        }
    }
}

public enum DesktopServiceAvailability: Equatable, Sendable {
    case healthy
    case transitional
    case failed
    case absent
    case unknown

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .transitional: return "Transitioning"
        case .failed: return "Needs attention"
        case .absent: return "Not observed"
        case .unknown: return "Unknown"
        }
    }

    public var systemImage: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .transitional: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle.fill"
        case .absent: return "minus.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

public struct DesktopServiceStatus: Equatable, Identifiable, Sendable {
    public let id: String
    public let desiredImage: String?
    public let resourceIdentifier: String?
    public let observedImage: String?
    public let lifecycle: String?
    public let health: String?

    public init(
        id: String,
        desiredImage: String?,
        resourceIdentifier: String?,
        observedImage: String?,
        lifecycle: String?,
        health: String?
    ) {
        self.id = id
        self.desiredImage = desiredImage
        self.resourceIdentifier = resourceIdentifier
        self.observedImage = observedImage
        self.lifecycle = lifecycle
        self.health = health
    }

    public var availability: DesktopServiceAvailability {
        guard let lifecycle else { return .absent }
        if ["failed", "error", "exited", "terminated"].contains(lifecycle) {
            return .failed
        }
        if health == "unhealthy" || health == "failed" {
            return .failed
        }
        if lifecycle == "running" && (health == "healthy" || health == "not-configured") {
            return .healthy
        }
        if ["created", "starting", "stopping", "restarting", "unknown"].contains(lifecycle) {
            return .transitional
        }
        return .unknown
    }

    public var detailLabel: String {
        let lifecycle = lifecycle ?? "not observed"
        if let health {
            return "\(lifecycle), \(health)"
        }
        return lifecycle
    }
}

public struct DesktopProjectStatus: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let manifestPath: String
    public let manifestIsValid: Bool
    public let services: [DesktopServiceStatus]
    public let planHash: String?

    public init(
        id: String,
        name: String,
        manifestPath: String,
        manifestIsValid: Bool,
        services: [DesktopServiceStatus],
        planHash: String?
    ) {
        self.id = id
        self.name = name
        self.manifestPath = manifestPath
        self.manifestIsValid = manifestIsValid
        self.services = services
        self.planHash = planHash
    }

    public var availability: DesktopServiceAvailability {
        guard !services.isEmpty else { return .unknown }
        if services.contains(where: { $0.availability == .failed }) { return .failed }
        if services.allSatisfy({ $0.availability == .healthy }) { return .healthy }
        return .transitional
    }
}

public struct DesktopEvent: Equatable, Identifiable, Sendable {
    public let id: String
    public let position: Int64
    public let timestamp: String
    public let severity: String
    public let type: String
    public let source: String
    public let projectID: String?
    public let serviceName: String?
    public let runtimeAdapter: String?
    public let message: String
    public let payloadJSONRedacted: String
    public let eventReference: String
    public let operationReferences: [String]

    public init(
        id: String,
        position: Int64,
        timestamp: String,
        severity: String,
        type: String,
        source: String,
        projectID: String?,
        serviceName: String?,
        runtimeAdapter: String?,
        message: String,
        payloadJSONRedacted: String,
        eventReference: String,
        operationReferences: [String]
    ) {
        self.id = id
        self.position = position
        self.timestamp = timestamp
        self.severity = severity
        self.type = type
        self.source = source
        self.projectID = projectID
        self.serviceName = serviceName
        self.runtimeAdapter = runtimeAdapter
        self.message = message
        self.payloadJSONRedacted = payloadJSONRedacted
        self.eventReference = eventReference
        self.operationReferences = operationReferences
    }
}

public struct DesktopLogChunk: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let text: String

    public init(id: Int64, text: String) {
        self.id = id
        self.text = text
    }
}

public struct DesktopEventFilter: Equatable, Sendable {
    public let projectID: String?
    public let type: String?
    public let serviceName: String?
    public let severity: String?
    public let endAfterSnapshot: Bool
    public let maximumEvents: Int?
    public let waitForFirst: Bool
    public let cursor: String?

    public init(
        projectID: String? = nil,
        type: String? = nil,
        serviceName: String? = nil,
        severity: String? = nil,
        endAfterSnapshot: Bool = true,
        maximumEvents: Int? = 100,
        waitForFirst: Bool = false,
        cursor: String? = nil
    ) {
        self.projectID = projectID
        self.type = type
        self.serviceName = serviceName
        self.severity = severity
        self.endAfterSnapshot = endAfterSnapshot
        self.maximumEvents = maximumEvents
        self.waitForFirst = waitForFirst
        self.cursor = cursor
    }
}
