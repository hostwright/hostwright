import Foundation
import HostwrightCore
import HostwrightNetworking

public enum RuntimeProjectDNSError: Error, Equatable, Sendable {
    case incompleteRequirement
    case invalidRequirement
    case unavailable
    case conflictingInfrastructure
}

public struct RuntimeProjectDNSRequirement: Equatable, Sendable {
    public let projectUUID: String
    public let resourceUUID: String
    public let zone: String

    public init(
        projectUUID: String,
        resourceUUID: String,
        zone: String
    ) throws {
        guard let project = UUID(uuidString: projectUUID),
              project.uuidString.lowercased() == projectUUID,
              let resource = UUID(uuidString: resourceUUID),
              resource.uuidString.lowercased() == resourceUUID,
              resourceUUID == HostwrightResourceUUID.legacy(
                  kind: "project-dns",
                  identifier: projectUUID
              ),
              projectUUID != resourceUUID,
              zone ==
                "\(projectUUID).\(ProjectDNSPlanner.zoneSuffix)",
              zone.utf8.count <= 253 else {
            throw RuntimeProjectDNSError.invalidRequirement
        }
        self.projectUUID = projectUUID
        self.resourceUUID = resourceUUID
        self.zone = zone
    }
}

public enum RuntimeProjectDNSContract {
    public static let resourceUUIDLabel =
        "dev.hostwright.project-dns-uuid"
    public static let zoneLabel =
        "dev.hostwright.project-dns-zone"
    public static let resourceKindLabel =
        "dev.hostwright.resource-kind"
    public static let resourceKind = "project-dns"

    public static let internalLabelKeys: Set<String> = [
        resourceUUIDLabel,
        zoneLabel,
        resourceKindLabel
    ]

    public static func workloadLabels(
        projectUUID: String
    ) throws -> [String: String] {
        let resourceUUID = HostwrightResourceUUID.legacy(
            kind: "project-dns",
            identifier: projectUUID
        )
        let requirement = try RuntimeProjectDNSRequirement(
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            zone:
                "\(projectUUID).\(ProjectDNSPlanner.zoneSuffix)"
        )
        return [
            resourceUUIDLabel: requirement.resourceUUID,
            zoneLabel: requirement.zone
        ]
    }

    public static func infrastructureLabels(
        projectUUID: String
    ) throws -> [String: String] {
        var labels = try workloadLabels(projectUUID: projectUUID)
        labels[resourceKindLabel] = resourceKind
        return labels
    }

    public static func requirement(
        from labels: [String: String],
        projectUUID: String
    ) throws -> RuntimeProjectDNSRequirement? {
        let present = internalLabelKeys.filter {
            labels[$0] != nil
        }
        guard !present.isEmpty else { return nil }
        guard let resourceUUID = labels[resourceUUIDLabel],
              let zone = labels[zoneLabel],
              labels[resourceKindLabel] == nil ||
                labels[resourceKindLabel] == resourceKind else {
            throw RuntimeProjectDNSError.incompleteRequirement
        }
        return try RuntimeProjectDNSRequirement(
            projectUUID: projectUUID,
            resourceUUID: resourceUUID,
            zone: zone
        )
    }

    public static func isInfrastructure(
        _ labels: [String: String]
    ) -> Bool {
        labels[resourceKindLabel] == resourceKind
    }
}
