import Foundation
import HostwrightRuntime

public enum DesktopTopologyProjectionError: Error, Equatable, Sendable {
    case limitExceeded(String)
    case invalidIdentifier(role: String, value: String)
    case duplicateIdentifier(role: String, value: String)
    case conflictingIdentifier(role: String, value: String)
    case invalidDocument(String)
}

public enum DesktopTopologyScope: String, Codable, Equatable, Sendable {
    case localReportedOnly = "local-reported-only"
}

public enum DesktopTopologyNodeKind: String, Codable, Equatable, Hashable, Sendable {
    case daemon
    case project
    case service
    case runtimeResource = "runtime-resource"
}

public enum DesktopTopologyEdgeKind: String, Codable, Equatable, Hashable, Sendable {
    case projectReportsService = "project-reports-service"
    case serviceReportsRuntimeResource = "service-reports-runtime-resource"
}

public enum DesktopTopologySeverity: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case normal
    case transitional
    case warning
    case critical
    case unavailable

    public var accessibilityLabel: String {
        switch self {
        case .unknown: return "Unknown"
        case .normal: return "Normal"
        case .transitional: return "Transitional"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unavailable: return "Unavailable"
        }
    }
}

public struct DesktopTopologyNode: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: DesktopTopologyNodeKind
    public let label: String
    public let reportedState: String
    public let reportedHealth: String?
    public let severity: DesktopTopologySeverity
    public let detail: String
    public let accessibilitySummary: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case kind
        case label
        case reportedState
        case reportedHealth
        case severity
        case detail
        case accessibilitySummary
    }

    public init(
        id: String,
        kind: DesktopTopologyNodeKind,
        label: String,
        reportedState: String,
        reportedHealth: String?,
        severity: DesktopTopologySeverity,
        detail: String,
        accessibilitySummary: String
    ) throws {
        try DesktopTopologyBoundary.requireNodeIdentifier(id, kind: kind)
        try DesktopTopologyBoundary.requireCanonicalText(label, maximumBytes: 96, field: "node.label")
        try DesktopTopologyBoundary.requireCanonicalText(
            reportedState,
            maximumBytes: 64,
            field: "node.reportedState"
        )
        if let reportedHealth {
            try DesktopTopologyBoundary.requireCanonicalText(
                reportedHealth,
                maximumBytes: 64,
                field: "node.reportedHealth"
            )
        }
        try DesktopTopologyBoundary.requireCanonicalText(detail, maximumBytes: 256, field: "node.detail")
        try DesktopTopologyBoundary.requireCanonicalText(
            accessibilitySummary,
            maximumBytes: 320,
            field: "node.accessibilitySummary"
        )
        self.id = id
        self.kind = kind
        self.label = label
        self.reportedState = reportedState
        self.reportedHealth = reportedHealth
        self.severity = severity
        self.detail = detail
        self.accessibilitySummary = accessibilitySummary
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopologyKeys(
            decoder,
            CodingKeys.self,
            path: "node",
            required: Set(CodingKeys.allCases).subtracting([.reportedHealth])
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(DesktopTopologyNodeKind.self, forKey: .kind),
            label: values.decode(String.self, forKey: .label),
            reportedState: values.decode(String.self, forKey: .reportedState),
            reportedHealth: values.decodeIfPresent(String.self, forKey: .reportedHealth),
            severity: values.decode(DesktopTopologySeverity.self, forKey: .severity),
            detail: values.decode(String.self, forKey: .detail),
            accessibilitySummary: values.decode(String.self, forKey: .accessibilitySummary)
        )
    }
}

public struct DesktopTopologyEdge: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: DesktopTopologyEdgeKind
    public let sourceNodeID: String
    public let targetNodeID: String
    public let accessibilitySummary: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case kind
        case sourceNodeID
        case targetNodeID
        case accessibilitySummary
    }

    public init(
        id: String,
        kind: DesktopTopologyEdgeKind,
        sourceNodeID: String,
        targetNodeID: String,
        accessibilitySummary: String
    ) throws {
        try DesktopTopologyBoundary.requireEdgeIdentifier(id, kind: kind)
        try DesktopTopologyBoundary.requireOutputIdentifier(sourceNodeID, role: "edge-source")
        try DesktopTopologyBoundary.requireOutputIdentifier(targetNodeID, role: "edge-target")
        guard sourceNodeID != targetNodeID else {
            throw DesktopTopologyProjectionError.invalidDocument("A topology edge cannot reference itself.")
        }
        try DesktopTopologyBoundary.requireCanonicalText(
            accessibilitySummary,
            maximumBytes: 256,
            field: "edge.accessibilitySummary"
        )
        self.id = id
        self.kind = kind
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.accessibilitySummary = accessibilitySummary
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopologyKeys(decoder, CodingKeys.self, path: "edge")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            kind: values.decode(DesktopTopologyEdgeKind.self, forKey: .kind),
            sourceNodeID: values.decode(String.self, forKey: .sourceNodeID),
            targetNodeID: values.decode(String.self, forKey: .targetNodeID),
            accessibilitySummary: values.decode(String.self, forKey: .accessibilitySummary)
        )
    }
}

public struct DesktopTopologyDiagnostic: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let severity: DesktopTopologySeverity
    public let summary: String
    public let detail: String
    public let relatedNodeIDs: [String]
    public let reportedRuntimeAdapter: String?
    public let accessibilitySummary: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case severity
        case summary
        case detail
        case relatedNodeIDs
        case reportedRuntimeAdapter
        case accessibilitySummary
    }

    public init(
        id: String,
        severity: DesktopTopologySeverity,
        summary: String,
        detail: String,
        relatedNodeIDs: [String],
        reportedRuntimeAdapter: String?,
        accessibilitySummary: String
    ) throws {
        try DesktopTopologyBoundary.requireDiagnosticIdentifier(id)
        try DesktopTopologyBoundary.requireCanonicalText(
            summary,
            maximumBytes: 160,
            field: "diagnostic.summary"
        )
        try DesktopTopologyBoundary.requireCanonicalText(
            detail,
            maximumBytes: 256,
            field: "diagnostic.detail"
        )
        guard relatedNodeIDs == relatedNodeIDs.sorted(),
              Set(relatedNodeIDs).count == relatedNodeIDs.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Diagnostic node references must be unique and sorted."
            )
        }
        for nodeID in relatedNodeIDs {
            try DesktopTopologyBoundary.requireOutputIdentifier(nodeID, role: "diagnostic-node")
        }
        if let reportedRuntimeAdapter {
            try DesktopTopologyBoundary.requireCanonicalText(
                reportedRuntimeAdapter,
                maximumBytes: 96,
                field: "diagnostic.reportedRuntimeAdapter"
            )
        }
        try DesktopTopologyBoundary.requireCanonicalText(
            accessibilitySummary,
            maximumBytes: 320,
            field: "diagnostic.accessibilitySummary"
        )
        self.id = id
        self.severity = severity
        self.summary = summary
        self.detail = detail
        self.relatedNodeIDs = relatedNodeIDs
        self.reportedRuntimeAdapter = reportedRuntimeAdapter
        self.accessibilitySummary = accessibilitySummary
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopologyKeys(
            decoder,
            CodingKeys.self,
            path: "diagnostic",
            required: Set(CodingKeys.allCases).subtracting([.reportedRuntimeAdapter])
        )
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(String.self, forKey: .id),
            severity: values.decode(DesktopTopologySeverity.self, forKey: .severity),
            summary: values.decode(String.self, forKey: .summary),
            detail: values.decode(String.self, forKey: .detail),
            relatedNodeIDs: values.decode([String].self, forKey: .relatedNodeIDs),
            reportedRuntimeAdapter: values.decodeIfPresent(
                String.self,
                forKey: .reportedRuntimeAdapter
            ),
            accessibilitySummary: values.decode(String.self, forKey: .accessibilitySummary)
        )
    }
}

public struct DesktopTopologyDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let supportedSubsetIdentifier = "desktop-local-reported-topology-v1"

    public let schemaVersion: Int
    public let supportedSubset: String
    public let scope: DesktopTopologyScope
    public let nodes: [DesktopTopologyNode]
    public let edges: [DesktopTopologyEdge]
    public let diagnostics: [DesktopTopologyDiagnostic]
    public let accessibilitySummary: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case supportedSubset
        case scope
        case nodes
        case edges
        case diagnostics
        case accessibilitySummary
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        supportedSubset: String = Self.supportedSubsetIdentifier,
        scope: DesktopTopologyScope = .localReportedOnly,
        nodes: [DesktopTopologyNode],
        edges: [DesktopTopologyEdge],
        diagnostics: [DesktopTopologyDiagnostic],
        accessibilitySummary: String
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              supportedSubset == Self.supportedSubsetIdentifier,
              scope == .localReportedOnly else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology document contract is unsupported."
            )
        }
        guard nodes.count <= DesktopTopologyBoundary.maximumNodes,
              edges.count <= DesktopTopologyBoundary.maximumEdges,
              diagnostics.count <= DesktopTopologyBoundary.maximumEvents else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology document exceeds its bounded subset."
            )
        }
        guard nodes.map(\.id) == nodes.map(\.id).sorted(),
              Set(nodes.map(\.id)).count == nodes.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Topology nodes must be unique and sorted."
            )
        }
        guard edges.map(\.id) == edges.map(\.id).sorted(),
              Set(edges.map(\.id)).count == edges.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Topology edges must be unique and sorted."
            )
        }
        let edgeRelationships = edges.map {
            "\($0.kind.rawValue)|\($0.sourceNodeID)|\($0.targetNodeID)"
        }
        guard Set(edgeRelationships).count == edgeRelationships.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Topology relationships must be unique."
            )
        }
        let reportedServiceTargets = edges
            .filter { $0.kind == .projectReportsService }
            .map(\.targetNodeID)
        let runtimeRelationships = edges.filter {
            $0.kind == .serviceReportsRuntimeResource
        }
        guard Set(reportedServiceTargets).count == reportedServiceTargets.count,
              Set(runtimeRelationships.map(\.sourceNodeID)).count == runtimeRelationships.count,
              Set(runtimeRelationships.map(\.targetNodeID)).count == runtimeRelationships.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Reported service and runtime relationships are ambiguous."
            )
        }
        guard diagnostics.map(\.id) == diagnostics.map(\.id).sorted(),
              Set(diagnostics.map(\.id)).count == diagnostics.count else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Topology diagnostics must be unique and sorted."
            )
        }
        let nodeIDs = Set(nodes.map(\.id))
        let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard edges.allSatisfy({
            nodeIDs.contains($0.sourceNodeID) && nodeIDs.contains($0.targetNodeID)
        }), diagnostics.allSatisfy({ diagnostic in
            diagnostic.relatedNodeIDs.allSatisfy(nodeIDs.contains)
        }) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "Topology relationships must reference reported nodes."
            )
        }
        guard edges.allSatisfy({ edge in
            guard let source = nodesByID[edge.sourceNodeID],
                  let target = nodesByID[edge.targetNodeID] else {
                return false
            }
            switch edge.kind {
            case .projectReportsService:
                return source.kind == .project && target.kind == .service
            case .serviceReportsRuntimeResource:
                return source.kind == .service && target.kind == .runtimeResource
            }
        }) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "A topology relationship has incompatible node kinds."
            )
        }
        try DesktopTopologyBoundary.requireCanonicalText(
            accessibilitySummary,
            maximumBytes: 320,
            field: "document.accessibilitySummary"
        )
        self.schemaVersion = schemaVersion
        self.supportedSubset = supportedSubset
        self.scope = scope
        self.nodes = nodes
        self.edges = edges
        self.diagnostics = diagnostics
        self.accessibilitySummary = accessibilitySummary
    }

    public init(from decoder: Decoder) throws {
        try requireExactTopologyKeys(decoder, CodingKeys.self, path: "document")
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            supportedSubset: values.decode(String.self, forKey: .supportedSubset),
            scope: values.decode(DesktopTopologyScope.self, forKey: .scope),
            nodes: values.decode([DesktopTopologyNode].self, forKey: .nodes),
            edges: values.decode([DesktopTopologyEdge].self, forKey: .edges),
            diagnostics: values.decode([DesktopTopologyDiagnostic].self, forKey: .diagnostics),
            accessibilitySummary: values.decode(String.self, forKey: .accessibilitySummary)
        )
    }
}

public enum DesktopTopologyWireContract {
    public static func encode(_ document: DesktopTopologyDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    public static func decode(_ data: Data) throws -> DesktopTopologyDocument {
        try DesktopTopologyStrictJSON.validate(data)
        return try JSONDecoder().decode(DesktopTopologyDocument.self, from: data)
    }
}

public enum DesktopTopologyProjector {
    public static func project(
        daemonHealth: DesktopDaemonHealth?,
        projects: [DesktopProjectStatus],
        events: [DesktopEvent]
    ) throws -> DesktopTopologyDocument {
        guard projects.count <= DesktopTopologyBoundary.maximumProjects else {
            throw DesktopTopologyProjectionError.limitExceeded("projects")
        }
        guard events.count <= DesktopTopologyBoundary.maximumEvents else {
            throw DesktopTopologyProjectionError.limitExceeded("events")
        }

        var nodes: [DesktopTopologyNode] = []
        var edges: [DesktopTopologyEdge] = []
        var diagnostics: [DesktopTopologyDiagnostic] = []
        var projectNodeByReportedID: [String: String] = [:]
        var serviceNodeByReportedKey: [DesktopReportedServiceKey: String] = [:]
        var serviceNodeByRuntimeResource: [String: String] = [:]

        if let daemonHealth {
            nodes.append(try daemonNode(daemonHealth))
        }

        for project in projects {
            let projectID = try DesktopTopologyBoundary.requireInputIdentifier(
                project.id,
                role: "project"
            )
            guard projectNodeByReportedID[projectID] == nil else {
                throw DesktopTopologyProjectionError.duplicateIdentifier(
                    role: "project",
                    value: DesktopTopologyBoundary.reportedValue(projectID)
                )
            }
            guard project.services.count <= DesktopTopologyBoundary.maximumServicesPerProject else {
                throw DesktopTopologyProjectionError.limitExceeded("services")
            }

            let projectNodeID = DesktopTopologyBoundary.nodeID(kind: .project, components: [projectID])
            projectNodeByReportedID[projectID] = projectNodeID
            let projectLabel = DesktopTopologyBoundary.safeText(
                project.name,
                fallback: "Project",
                maximumBytes: 96
            )
            let projectState = project.manifestIsValid ? "manifest-valid" : "manifest-invalid"
            let projectSeverity: DesktopTopologySeverity = project.manifestIsValid ? .unknown : .critical
            nodes.append(
                try DesktopTopologyNode(
                    id: projectNodeID,
                    kind: .project,
                    label: projectLabel,
                    reportedState: projectState,
                    reportedHealth: nil,
                    severity: projectSeverity,
                    detail: project.manifestIsValid
                        ? "Reported manifest status is valid."
                        : "Reported manifest status is invalid.",
                    accessibilitySummary: nodeAccessibilitySummary(
                        kind: "Project",
                        label: projectLabel,
                        state: projectState,
                        health: nil,
                        severity: projectSeverity
                    )
                )
            )
            try requireTopologyBounds(nodes: nodes, edges: edges)

            for service in project.services {
                let serviceID = try DesktopTopologyBoundary.requireInputIdentifier(
                    service.id,
                    role: "service"
                )
                let serviceKey = DesktopReportedServiceKey(
                    projectID: projectID,
                    serviceID: serviceID
                )
                guard serviceNodeByReportedKey[serviceKey] == nil else {
                    throw DesktopTopologyProjectionError.duplicateIdentifier(
                        role: "service",
                        value: DesktopTopologyBoundary.reportedValue(
                            "\(projectID)/\(serviceID)"
                        )
                    )
                }

                let serviceNodeID = DesktopTopologyBoundary.nodeID(
                    kind: .service,
                    components: [projectID, serviceID]
                )
                serviceNodeByReportedKey[serviceKey] = serviceNodeID
                let state = DesktopTopologyBoundary.safeText(
                    service.lifecycle ?? "unknown",
                    fallback: "unknown",
                    maximumBytes: 64
                )
                let health = service.health.map {
                    DesktopTopologyBoundary.safeText(
                        $0,
                        fallback: "unknown",
                        maximumBytes: 64
                    )
                }
                let severity = serviceSeverity(lifecycle: service.lifecycle, health: service.health)
                let serviceLabel = DesktopTopologyBoundary.safeText(
                    serviceID,
                    fallback: "Service",
                    maximumBytes: 96
                )
                nodes.append(
                    try DesktopTopologyNode(
                        id: serviceNodeID,
                        kind: .service,
                        label: serviceLabel,
                        reportedState: state,
                        reportedHealth: health,
                        severity: severity,
                        detail: serviceDetail(state: state, health: health),
                        accessibilitySummary: nodeAccessibilitySummary(
                            kind: "Service",
                            label: serviceLabel,
                            state: state,
                            health: health,
                            severity: severity
                        )
                    )
                )
                edges.append(
                    try DesktopTopologyEdge(
                        id: DesktopTopologyBoundary.edgeID(
                            kind: .projectReportsService,
                            components: [projectID, serviceID]
                        ),
                        kind: .projectReportsService,
                        sourceNodeID: projectNodeID,
                        targetNodeID: serviceNodeID,
                        accessibilitySummary: DesktopTopologyBoundary.safeText(
                            "Project \(projectLabel) reports service \(serviceLabel).",
                            fallback: "A project reports a service.",
                            maximumBytes: 256
                        )
                    )
                )
                try requireTopologyBounds(nodes: nodes, edges: edges)

                guard let rawRuntimeResourceID = service.resourceIdentifier else { continue }
                let runtimeResourceID = try DesktopTopologyBoundary.requireInputIdentifier(
                    rawRuntimeResourceID,
                    role: "runtime-resource"
                )
                guard serviceNodeByRuntimeResource[runtimeResourceID] == nil else {
                    throw DesktopTopologyProjectionError.conflictingIdentifier(
                        role: "runtime-resource",
                        value: DesktopTopologyBoundary.reportedValue(runtimeResourceID)
                    )
                }
                serviceNodeByRuntimeResource[runtimeResourceID] = serviceNodeID
                let runtimeNodeID = DesktopTopologyBoundary.nodeID(
                    kind: .runtimeResource,
                    components: [runtimeResourceID]
                )
                nodes.append(
                    try DesktopTopologyNode(
                        id: runtimeNodeID,
                        kind: .runtimeResource,
                        label: "Runtime resource",
                        reportedState: state,
                        reportedHealth: health,
                        severity: severity,
                        detail: DesktopTopologyBoundary.safeText(
                            "Reported for service \(serviceLabel).",
                            fallback: "Reported runtime resource.",
                            maximumBytes: 256
                        ),
                        accessibilitySummary: nodeAccessibilitySummary(
                            kind: "Runtime resource",
                            label: serviceLabel,
                            state: state,
                            health: health,
                            severity: severity
                        )
                    )
                )
                edges.append(
                    try DesktopTopologyEdge(
                        id: DesktopTopologyBoundary.edgeID(
                            kind: .serviceReportsRuntimeResource,
                            components: [projectID, serviceID, runtimeResourceID]
                        ),
                        kind: .serviceReportsRuntimeResource,
                        sourceNodeID: serviceNodeID,
                        targetNodeID: runtimeNodeID,
                        accessibilitySummary: DesktopTopologyBoundary.safeText(
                            "Service \(serviceLabel) reports a runtime resource.",
                            fallback: "A service reports a runtime resource.",
                            maximumBytes: 256
                        )
                    )
                )
                try requireTopologyBounds(nodes: nodes, edges: edges)
            }
        }

        var eventIDs = Set<String>()
        for event in events {
            let eventID = try DesktopTopologyBoundary.requireInputIdentifier(
                event.id,
                role: "event"
            )
            guard eventIDs.insert(eventID).inserted else {
                throw DesktopTopologyProjectionError.duplicateIdentifier(
                    role: "event",
                    value: DesktopTopologyBoundary.reportedValue(eventID)
                )
            }

            var relatedNodeIDs: [String] = []
            let eventProjectID = try event.projectID.map {
                try DesktopTopologyBoundary.requireInputIdentifier($0, role: "event-project")
            }
            let eventServiceName = try event.serviceName.map {
                try DesktopTopologyBoundary.requireInputIdentifier($0, role: "event-service")
            }
            if let projectID = eventProjectID {
                if let projectNodeID = projectNodeByReportedID[projectID] {
                    relatedNodeIDs.append(projectNodeID)
                    if let serviceName = eventServiceName {
                        let serviceKey = DesktopReportedServiceKey(
                            projectID: projectID,
                            serviceID: serviceName
                        )
                        if let serviceNodeID = serviceNodeByReportedKey[serviceKey] {
                            relatedNodeIDs.append(serviceNodeID)
                        }
                    }
                }
            }

            let severity = eventSeverity(event.severity)
            let type = DesktopTopologyBoundary.safeText(
                event.type,
                fallback: "unknown-event",
                maximumBytes: 96
            )
            let source = DesktopTopologyBoundary.safeText(
                event.source,
                fallback: "unknown-source",
                maximumBytes: 96
            )
            let message = DesktopTopologyBoundary.safeText(
                event.message,
                fallback: "No safe event detail was reported.",
                maximumBytes: 192
            )
            let runtimeAdapter = event.runtimeAdapter.map {
                DesktopTopologyBoundary.safeText(
                    $0,
                    fallback: "unknown-runtime-adapter",
                    maximumBytes: 96
                )
            }
            let summary = DesktopTopologyBoundary.safeText(
                "\(severity.accessibilityLabel) event: \(type)",
                fallback: "Reported event with unknown severity.",
                maximumBytes: 160
            )
            let detail = DesktopTopologyBoundary.safeText(
                "Source \(source). \(message)",
                fallback: "Reported event detail is unavailable.",
                maximumBytes: 256
            )
            diagnostics.append(
                try DesktopTopologyDiagnostic(
                    id: DesktopTopologyBoundary.diagnosticID(eventID: eventID),
                    severity: severity,
                    summary: summary,
                    detail: detail,
                    relatedNodeIDs: relatedNodeIDs.sorted(),
                    reportedRuntimeAdapter: runtimeAdapter,
                    accessibilitySummary: DesktopTopologyBoundary.safeText(
                        "Event. Severity \(severity.accessibilityLabel). Type \(type).",
                        fallback: "Event. Severity Unknown.",
                        maximumBytes: 320
                    )
                )
            )
        }

        nodes.sort { $0.id < $1.id }
        edges.sort { $0.id < $1.id }
        diagnostics.sort { $0.id < $1.id }
        try requireTopologyBounds(nodes: nodes, edges: edges)

        return try DesktopTopologyDocument(
            nodes: nodes,
            edges: edges,
            diagnostics: diagnostics,
            accessibilitySummary: "Reported local topology: \(nodes.count) nodes, \(edges.count) explicit relationships, and \(diagnostics.count) event diagnostics. Unknown states remain unknown."
        )
    }

    private static func daemonNode(_ health: DesktopDaemonHealth) throws -> DesktopTopologyNode {
        let state = DesktopTopologyBoundary.safeText(
            health.readiness,
            fallback: "unknown",
            maximumBytes: 64
        )
        let label = DesktopTopologyBoundary.safeText(
            health.label,
            fallback: "Hostwright daemon",
            maximumBytes: 96
        )
        let severity = daemonSeverity(health.readiness)
        let reason = DesktopTopologyBoundary.safeText(
            health.reasonCode,
            fallback: "unknown",
            maximumBytes: 64
        )
        let domain = DesktopTopologyBoundary.safeText(
            health.domain,
            fallback: "local",
            maximumBytes: 64
        )
        return try DesktopTopologyNode(
            id: "node.daemon.local",
            kind: .daemon,
            label: label,
            reportedState: state,
            reportedHealth: nil,
            severity: severity,
            detail: DesktopTopologyBoundary.safeText(
                "Reported reason \(reason) in domain \(domain).",
                fallback: "Reported daemon detail is unavailable.",
                maximumBytes: 256
            ),
            accessibilitySummary: nodeAccessibilitySummary(
                kind: "Daemon",
                label: label,
                state: state,
                health: nil,
                severity: severity
            )
        )
    }

    private static func daemonSeverity(_ readiness: String) -> DesktopTopologySeverity {
        switch readiness {
        case "running": return .normal
        case "recovery-required": return .critical
        case "stopped", "not-installed", "disabled": return .unavailable
        default: return .unknown
        }
    }

    private static func serviceSeverity(
        lifecycle: String?,
        health: String?
    ) -> DesktopTopologySeverity {
        if health == "unhealthy" || health == "failed" {
            return .critical
        }
        if lifecycle.map({ ["failed", "error", "exited", "terminated"].contains($0) }) == true {
            return .critical
        }
        if lifecycle == "stopped" || lifecycle == "missing" {
            return .unavailable
        }
        if health == "starting"
            || lifecycle.map({ ["created", "starting", "stopping", "restarting"].contains($0) }) == true {
            return .transitional
        }
        if lifecycle == "running" && health == "healthy" {
            return .normal
        }
        return .unknown
    }

    private static func eventSeverity(_ severity: String) -> DesktopTopologySeverity {
        switch severity {
        case "info": return .normal
        case "warning": return .warning
        case "error": return .critical
        default: return .unknown
        }
    }

    private static func requireTopologyBounds(
        nodes: [DesktopTopologyNode],
        edges: [DesktopTopologyEdge]
    ) throws {
        guard nodes.count <= DesktopTopologyBoundary.maximumNodes,
              edges.count <= DesktopTopologyBoundary.maximumEdges else {
            throw DesktopTopologyProjectionError.limitExceeded("topology")
        }
    }

    private static func serviceDetail(state: String, health: String?) -> String {
        if let health {
            return DesktopTopologyBoundary.safeText(
                "Reported lifecycle \(state). Reported health \(health).",
                fallback: "Reported service state is unavailable.",
                maximumBytes: 256
            )
        }
        return DesktopTopologyBoundary.safeText(
            "Reported lifecycle \(state). Reported health unknown.",
            fallback: "Reported service state is unavailable.",
            maximumBytes: 256
        )
    }

    private static func nodeAccessibilitySummary(
        kind: String,
        label: String,
        state: String,
        health: String?,
        severity: DesktopTopologySeverity
    ) -> String {
        let healthText = health.map { "; health \($0)" } ?? ""
        return DesktopTopologyBoundary.safeText(
            "\(kind) \(label). State \(state)\(healthText). Severity \(severity.accessibilityLabel).",
            fallback: "\(kind). State unknown. Severity Unknown.",
            maximumBytes: 320
        )
    }
}

private struct DesktopReportedServiceKey: Hashable {
    let projectID: String
    let serviceID: String
}

private struct DesktopTopologyAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum DesktopTopologyBoundary {
    static let maximumProjects = 256
    static let maximumServicesPerProject = 512
    static let maximumEvents = 1_000
    static let maximumNodes = 4_096
    static let maximumEdges = 4_096
    static let maximumJSONBytes = 262_144
    static let maximumJSONDepth = 64
    static let maximumJSONNodes = 16_384
    private static let maximumInputIdentifierBytes = 256
    private static let maximumOutputIdentifierBytes = 2_048

    static func requireInputIdentifier(_ value: String, role: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumInputIdentifierBytes,
              RuntimeRedactionPolicy.default.redact(value) == value,
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x21 && scalar.value <= 0x7e
              }) else {
            throw DesktopTopologyProjectionError.invalidIdentifier(
                role: role,
                value: reportedValue(value)
            )
        }
        return value
    }

    static func requireOutputIdentifier(_ value: String, role: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumOutputIdentifierBytes,
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || (scalar.value >= 0x61 && scalar.value <= 0x7a)
                      || scalar == "."
                      || scalar == "-"
              }) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The \(role) identifier is malformed."
            )
        }
    }

    static func requireNodeIdentifier(
        _ value: String,
        kind: DesktopTopologyNodeKind
    ) throws {
        try requireOutputIdentifier(value, role: "node")
        if kind == .daemon {
            guard value == "node.daemon.local" else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "The daemon topology identifier is malformed."
                )
            }
            return
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let expectedComponentCount = kind == .service ? 4 : 3
        guard components.count == expectedComponentCount,
              components[0] == "node",
              components[1] == Substring(kind.rawValue),
              components.dropFirst(2).allSatisfy({ isHexIdentifierComponent($0) }) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology node identifier does not match its kind."
            )
        }
    }

    static func requireEdgeIdentifier(
        _ value: String,
        kind: DesktopTopologyEdgeKind
    ) throws {
        try requireOutputIdentifier(value, role: "edge")
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        let expectedComponentCount = kind == .projectReportsService ? 4 : 5
        guard components.count == expectedComponentCount,
              components[0] == "edge",
              components[1] == Substring(kind.rawValue),
              components.dropFirst(2).allSatisfy({ isHexIdentifierComponent($0) }) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology edge identifier does not match its kind."
            )
        }
    }

    static func requireDiagnosticIdentifier(_ value: String) throws {
        try requireOutputIdentifier(value, role: "diagnostic")
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "diagnostic",
              components[1] == "event",
              isHexIdentifierComponent(components[2]) else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology diagnostic identifier is malformed."
            )
        }
    }

    static func safeText(
        _ value: String,
        fallback: String,
        maximumBytes: Int
    ) -> String {
        let redacted = RuntimeRedactionPolicy.default.redact(value)
        let controlFree = redacted.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = controlFree.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let source = normalized.isEmpty ? fallback : normalized
        var bounded = ""
        for character in source {
            let candidate = bounded + String(character)
            guard candidate.utf8.count <= maximumBytes else { break }
            bounded = candidate
        }
        return bounded.isEmpty ? fallback : bounded
    }

    static func reportedValue(_ value: String) -> String {
        safeText(value, fallback: "invalid", maximumBytes: 96)
    }

    static func requireCanonicalText(
        _ value: String,
        maximumBytes: Int,
        field: String
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              safeText(value, fallback: "invalid", maximumBytes: maximumBytes) == value else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The \(field) value is not canonical bounded text."
            )
        }
    }

    static func nodeID(kind: DesktopTopologyNodeKind, components: [String]) -> String {
        "node.\(kind.rawValue).\(components.map(hex).joined(separator: "."))"
    }

    static func edgeID(kind: DesktopTopologyEdgeKind, components: [String]) -> String {
        "edge.\(kind.rawValue).\(components.map(hex).joined(separator: "."))"
    }

    static func diagnosticID(eventID: String) -> String {
        "diagnostic.event.\(hex(eventID))"
    }

    private static func hex(_ value: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        let bytes = value.utf8.flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func isHexIdentifierComponent(_ value: Substring) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumInputIdentifierBytes * 2
            && value.utf8.count.isMultiple(of: 2)
            && value.utf8.allSatisfy { byte in
                (48...57).contains(byte) || (97...102).contains(byte)
            }
    }
}

private enum DesktopTopologyStrictJSON {
    private struct ObjectRule {
        let allowedKeys: Set<String>
        let requiredKeys: Set<String>
        let nestedRules: [String: ValueRule]
    }

    private indirect enum ValueRule {
        case object(ObjectRule)
        case array(ValueRule)
        case any
    }

    private static let nodeRule = ObjectRule(
        allowedKeys: [
            "id", "kind", "label", "reportedState", "reportedHealth", "severity", "detail",
            "accessibilitySummary",
        ],
        requiredKeys: [
            "id", "kind", "label", "reportedState", "severity", "detail",
            "accessibilitySummary",
        ],
        nestedRules: [:]
    )

    private static let edgeRule = ObjectRule(
        allowedKeys: [
            "id", "kind", "sourceNodeID", "targetNodeID", "accessibilitySummary",
        ],
        requiredKeys: [
            "id", "kind", "sourceNodeID", "targetNodeID", "accessibilitySummary",
        ],
        nestedRules: [:]
    )

    private static let diagnosticRule = ObjectRule(
        allowedKeys: [
            "id", "severity", "summary", "detail", "relatedNodeIDs",
            "reportedRuntimeAdapter", "accessibilitySummary",
        ],
        requiredKeys: [
            "id", "severity", "summary", "detail", "relatedNodeIDs",
            "accessibilitySummary",
        ],
        nestedRules: ["relatedNodeIDs": .array(.any)]
    )

    private static let documentRule = ObjectRule(
        allowedKeys: [
            "schemaVersion", "supportedSubset", "scope", "nodes", "edges", "diagnostics",
            "accessibilitySummary",
        ],
        requiredKeys: [
            "schemaVersion", "supportedSubset", "scope", "nodes", "edges", "diagnostics",
            "accessibilitySummary",
        ],
        nestedRules: [
            "nodes": .array(.object(nodeRule)),
            "edges": .array(.object(edgeRule)),
            "diagnostics": .array(.object(diagnosticRule)),
        ]
    )

    static func validate(_ data: Data) throws {
        guard data.count <= DesktopTopologyBoundary.maximumJSONBytes else {
            throw DesktopTopologyProjectionError.invalidDocument(
                "The topology JSON input exceeds its bounded subset."
            )
        }
        var parser = Parser(bytes: Array(data))
        try parser.validateTopLevelObject(using: documentRule)
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var depth = 0
        var nodes = 0

        mutating func validateTopLevelObject(using rule: ObjectRule) throws {
            try skipWhitespace()
            try parseObject(using: rule)
            try skipWhitespace()
            guard index == bytes.count else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "The topology document contains trailing content."
                )
            }
        }

        mutating func parseValue(using rule: ValueRule) throws {
            try countNode()
            switch rule {
            case .object(let objectRule):
                try parseObject(using: objectRule)
            case .array(let elementRule):
                try parseArray(of: elementRule)
            case .any:
                try skipValue()
            }
        }

        mutating func parseObject(using rule: ObjectRule) throws {
            try skipWhitespace()
            try enterContainer()
            defer { depth -= 1 }
            try require(byte: 123, message: "Expected a JSON object.")
            try skipWhitespace()
            var seen = Set<String>()
            var actual = Set<String>()
            if peek() == 125 {
                index += 1
            } else {
                while true {
                    let key = try parseString()
                    guard seen.insert(key).inserted else {
                        throw DesktopTopologyProjectionError.invalidDocument(
                            "A topology object contains a duplicate key."
                        )
                    }
                    guard rule.allowedKeys.contains(key) else {
                        throw DesktopTopologyProjectionError.invalidDocument(
                            "A topology object contains an unknown key."
                        )
                    }
                    actual.insert(key)
                    try skipWhitespace()
                    try require(byte: 58, message: "Expected a JSON object separator.")
                    try skipWhitespace()
                    try parseValue(using: rule.nestedRules[key] ?? .any)
                    try skipWhitespace()
                    if peek() == 44 {
                        index += 1
                        try skipWhitespace()
                        continue
                    }
                    try require(byte: 125, message: "Expected the end of a JSON object.")
                    break
                }
            }
            guard rule.requiredKeys.isSubset(of: actual) else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology object is missing a required key."
                )
            }
        }

        mutating func parseArray(of elementRule: ValueRule) throws {
            try skipWhitespace()
            try enterContainer()
            defer { depth -= 1 }
            try require(byte: 91, message: "Expected a JSON array.")
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
                try require(byte: 93, message: "Expected the end of a JSON array.")
                return
            }
        }

        mutating func skipValue() throws {
            try skipWhitespace()
            guard let byte = peek() else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology JSON value is truncated."
                )
            }
            try countNode()
            switch byte {
            case 123:
                try parseUntypedObject()
            case 91:
                try parseUntypedArray()
            case 34:
                _ = try parseString()
            case 116:
                try parseKeyword("true")
            case 102:
                try parseKeyword("false")
            case 110:
                try parseKeyword("null")
            case 45, 48...57:
                try parseNumber()
            default:
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology JSON value is malformed."
                )
            }
        }

        mutating func parseUntypedObject() throws {
            try enterContainer()
            defer { depth -= 1 }
            try require(byte: 123, message: "Expected a JSON object.")
            try skipWhitespace()
            if peek() == 125 {
                index += 1
                return
            }
            while true {
                _ = try parseString()
                try skipWhitespace()
                try require(byte: 58, message: "Expected a JSON object separator.")
                try skipWhitespace()
                try skipValue()
                try skipWhitespace()
                if peek() == 44 {
                    index += 1
                    try skipWhitespace()
                    continue
                }
                try require(byte: 125, message: "Expected the end of a JSON object.")
                return
            }
        }

        mutating func parseUntypedArray() throws {
            try enterContainer()
            defer { depth -= 1 }
            try require(byte: 91, message: "Expected a JSON array.")
            try skipWhitespace()
            if peek() == 93 {
                index += 1
                return
            }
            while true {
                try skipValue()
                try skipWhitespace()
                if peek() == 44 {
                    index += 1
                    try skipWhitespace()
                    continue
                }
                try require(byte: 93, message: "Expected the end of a JSON array.")
                return
            }
        }

        mutating func parseString() throws -> String {
            try skipWhitespace()
            try require(byte: 34, message: "Expected a JSON string.")
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
                        throw DesktopTopologyProjectionError.invalidDocument(
                            "A topology JSON string is malformed."
                        )
                    }
                    return value
                }
                index += 1
            }
            throw DesktopTopologyProjectionError.invalidDocument(
                "A topology JSON string is truncated."
            )
        }

        mutating func parseKeyword(_ keyword: StaticString) throws {
            let expected = Array("\(keyword)".utf8)
            guard bytes.dropFirst(index).starts(with: expected) else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology JSON keyword is malformed."
                )
            }
            index += expected.count
        }

        mutating func parseNumber() throws {
            let start = index
            if peek() == 45 { index += 1 }
            try consumeDigits(requireAtLeastOne: true)
            if peek() == 46 {
                index += 1
                try consumeDigits(requireAtLeastOne: true)
            }
            if let byte = peek(), byte == 101 || byte == 69 {
                index += 1
                if let sign = peek(), sign == 43 || sign == 45 {
                    index += 1
                }
                try consumeDigits(requireAtLeastOne: true)
            }
            guard index > start else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology JSON number is malformed."
                )
            }
        }

        mutating func consumeDigits(requireAtLeastOne: Bool) throws {
            let start = index
            while let byte = peek(), (48...57).contains(byte) {
                index += 1
            }
            guard !requireAtLeastOne || index > start else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "A topology JSON number is malformed."
                )
            }
        }

        mutating func skipWhitespace() throws {
            while let byte = peek(), [9, 10, 13, 32].contains(byte) {
                index += 1
            }
        }

        mutating func enterContainer() throws {
            depth += 1
            guard depth <= DesktopTopologyBoundary.maximumJSONDepth else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "The topology JSON input exceeds its bounded subset."
                )
            }
        }

        mutating func countNode() throws {
            nodes += 1
            guard nodes <= DesktopTopologyBoundary.maximumJSONNodes else {
                throw DesktopTopologyProjectionError.invalidDocument(
                    "The topology JSON input exceeds its bounded subset."
                )
            }
        }

        func peek() -> UInt8? {
            guard index < bytes.count else { return nil }
            return bytes[index]
        }

        mutating func require(byte expected: UInt8, message: String) throws {
            guard peek() == expected else {
                throw DesktopTopologyProjectionError.invalidDocument(message)
            }
            index += 1
        }
    }
}

private func requireExactTopologyKeys<Key: CodingKey & CaseIterable & Hashable>(
    _ decoder: Decoder,
    _ type: Key.Type,
    path: String,
    required: Set<Key>? = nil
) throws {
    let values = try decoder.container(keyedBy: DesktopTopologyAnyCodingKey.self)
    let actual = Set(values.allKeys.map(\.stringValue))
    let allowed = Set(type.allCases.map(\.stringValue))
    if let unknown = actual.subtracting(allowed).sorted().first {
        throw DesktopTopologyProjectionError.invalidDocument(
            "The topology \(path) field '\(unknown)' is unsupported."
        )
    }
    let requiredNames = Set((required ?? Set(type.allCases)).map(\.stringValue))
    if let missing = requiredNames.subtracting(actual).sorted().first {
        throw DesktopTopologyProjectionError.invalidDocument(
            "The topology \(path) field '\(missing)' is required."
        )
    }
}
