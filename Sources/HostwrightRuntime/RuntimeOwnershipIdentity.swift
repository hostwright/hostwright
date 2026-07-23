import CryptoKit
import Foundation

public enum RuntimeManagedResourceIdentityError: Error, Equatable, Sendable {
    case invalidMutationContext
    case incompleteOwnershipLabels
    case invalidOwnershipLabels
}

public enum RuntimeManagedResourceIdentity {
    public static let currentVersion = 2
    public static let maximumIdentifierLength = 63

    public static let managedLabel = "dev.hostwright.managed"
    public static let identityVersionLabel = "dev.hostwright.identity-version"
    public static let projectLabel = "dev.hostwright.project"
    public static let serviceLabel = "dev.hostwright.service"
    public static let instanceLabel = "dev.hostwright.instance"
    public static let resourceIdentifierLabel = "dev.hostwright.resource-id"
    public static let resourceUUIDLabel = "dev.hostwright.resource-uuid"
    public static let projectUUIDLabel = "dev.hostwright.project-uuid"
    public static let resourceGenerationLabel = "dev.hostwright.resource-generation"
    public static let projectGenerationLabel = "dev.hostwright.project-generation"
    public static let providerIDLabel = "dev.hostwright.provider-id"
    public static let providerGenerationLabel = "dev.hostwright.provider-generation"
    public static let fencingTokenLabel = "dev.hostwright.fencing-token"

    public static func resourceIdentifier(for identity: RuntimeServiceIdentity) -> String {
        let digest = identityDigest(identity)
        return "hostwright-v2-\(slug(identity.projectName))-\(slug(identity.serviceName))-\(digest)"
    }

    public static func legacyResourceIdentifier(for identity: RuntimeServiceIdentity) -> String {
        "hostwright-\(identity.projectName)-\(identity.serviceName)"
    }

    public static func labels(for identity: RuntimeServiceIdentity) -> [String: String] {
        var labels = [
            managedLabel: "true",
            identityVersionLabel: String(currentVersion),
            projectLabel: identity.projectName,
            serviceLabel: identity.serviceName,
            resourceIdentifierLabel: resourceIdentifier(for: identity)
        ]
        if let instanceName = identity.instanceName {
            labels[instanceLabel] = instanceName
        }
        return labels
    }

    public static func labels(
        for identity: RuntimeServiceIdentity,
        context: RuntimeMutationContext
    ) throws -> [String: String] {
        guard context.validationIssue == nil else {
            throw RuntimeManagedResourceIdentityError.invalidMutationContext
        }
        var result = labels(for: identity)
        result[resourceUUIDLabel] = context.resourceUUID.lowercased()
        result[projectUUIDLabel] = context.projectResourceUUID.lowercased()
        result[resourceGenerationLabel] = String(context.resourceGeneration)
        result[projectGenerationLabel] = String(context.projectGeneration)
        result[providerIDLabel] = context.providerID.rawValue
        result[providerGenerationLabel] = String(context.providerGeneration)
        result[fencingTokenLabel] = context.fencingToken.lowercased()
        return result
    }

    public static func ownershipEvidence(
        from labels: [String: String],
        expectedProviderID: RuntimeProviderID
    ) throws -> RuntimeInventoryOwnershipEvidence? {
        let ownershipKeys = [
            resourceUUIDLabel,
            projectUUIDLabel,
            resourceGenerationLabel,
            projectGenerationLabel,
            providerIDLabel,
            providerGenerationLabel,
            fencingTokenLabel
        ]
        let presentCount = ownershipKeys.reduce(into: 0) { count, key in
            if labels[key] != nil { count += 1 }
        }
        if labels[managedLabel] != "true" {
            guard presentCount == 0 else {
                throw RuntimeManagedResourceIdentityError.incompleteOwnershipLabels
            }
            return nil
        }
        guard presentCount == ownershipKeys.count,
              let resourceUUID = canonicalUUID(labels[resourceUUIDLabel]),
              let projectUUID = canonicalUUID(labels[projectUUIDLabel]),
              resourceUUID != projectUUID,
              let resourceGeneration = positiveInteger(labels[resourceGenerationLabel]),
              let projectGeneration = positiveInteger(labels[projectGenerationLabel]),
              labels[providerIDLabel] == expectedProviderID.rawValue,
              let providerGeneration = positiveInteger(labels[providerGenerationLabel]),
              let fencingToken = canonicalUUID(labels[fencingTokenLabel]) else {
            throw RuntimeManagedResourceIdentityError.invalidOwnershipLabels
        }
        return RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: resourceGeneration,
            projectGeneration: projectGeneration,
            providerID: expectedProviderID,
            providerGeneration: providerGeneration,
            fencingToken: fencingToken
        )
    }

    public static func identity(from labels: [String: String]) -> RuntimeServiceIdentity? {
        guard labels[managedLabel] == "true",
              labels[identityVersionLabel] == String(currentVersion),
              let projectName = labels[projectLabel],
              let serviceName = labels[serviceLabel],
              isDNSLikeName(projectName),
              isDNSLikeName(serviceName)
        else {
            return nil
        }

        let instanceName = labels[instanceLabel]
        if let instanceName, !isDNSLikeName(instanceName) {
            return nil
        }
        return RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName,
            instanceName: instanceName
        )
    }

    public static func labelsMatch(
        _ labels: [String: String],
        identity: RuntimeServiceIdentity,
        resourceIdentifier: String
    ) -> Bool {
        labels[resourceIdentifierLabel] == resourceIdentifier &&
            resourceIdentifier == self.resourceIdentifier(for: identity) &&
            self.identity(from: labels) == identity
    }

    public static func isManaged(_ labels: [String: String]) -> Bool {
        labels[managedLabel] == "true"
    }

    public static func isCurrentIdentifier(_ value: String) -> Bool {
        guard value.count <= maximumIdentifierLength else {
            return false
        }
        let segment = #"[a-z0-9](?:[a-z0-9-]{0,5}[a-z0-9])?"#
        let pattern = "^hostwright-v2-\(segment)-\(segment)-[a-f0-9]{32}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    public static func isLegacyIdentifier(_ value: String) -> Bool {
        guard value.count <= 255 else {
            return false
        }
        let pattern = #"^hostwright-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#
        return value.range(of: pattern, options: .regularExpression) != nil && !isCurrentIdentifier(value)
    }

    public static func isSupportedIdentifier(_ value: String) -> Bool {
        isCurrentIdentifier(value) || isLegacyIdentifier(value)
    }

    private static func identityDigest(_ identity: RuntimeServiceIdentity) -> String {
        let canonical = [
            component(identity.projectName),
            component(identity.serviceName),
            identity.instanceName.map(component) ?? "0:"
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func component(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    private static func slug(_ value: String) -> String {
        var normalized = ""
        var previousWasHyphen = false
        for scalar in value.lowercased().unicodeScalars {
            let scalarValue = scalar.value
            let isASCIIAlphaNumeric = (97...122).contains(scalarValue) ||
                (48...57).contains(scalarValue)
            if isASCIIAlphaNumeric {
                normalized.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen && !normalized.isEmpty {
                normalized.append("-")
                previousWasHyphen = true
            }
        }
        let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = String(trimmed.prefix(7)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return prefix.isEmpty ? "x" : prefix
    }

    private static func isDNSLikeName(_ value: String) -> Bool {
        let pattern = #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func canonicalUUID(_ value: String?) -> String? {
        guard let value,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            return nil
        }
        return value
    }

    private static func positiveInteger(_ value: String?) -> Int? {
        guard let value,
              value.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
              let number = Int(value),
              number > 0 else {
            return nil
        }
        return number
    }
}
