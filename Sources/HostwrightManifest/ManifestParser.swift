import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightSecrets
import Yams

public enum ManifestParser {
    public static let maximumUTF8Bytes = 1_048_576
    public static let maximumDepth = 64
    public static let maximumExpandedNodes = 100_000
    public static let limitation = "Hostwright Manifest v2 accepts one bounded YAML document."

    public static func parse(_ text: String) throws -> HostwrightManifest {
        try parse(text, cancellationCheck: { false })
    }

    public static func parse(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> HostwrightManifest {
        try checkCancellation(cancellationCheck)
        guard text.utf8.count <= maximumUTF8Bytes else {
            throw failure(
                "Manifest exceeds the 1 MiB UTF-8 limit.",
                code: .manifestUnsupportedFeature,
                path: "$"
            )
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw failure("Manifest contains a NUL scalar.", path: "$")
        }
        try preflightDepth(text)

        do {
            let parser = try Yams.Parser(yaml: text)
            guard let root = try parser.singleRoot() else {
                throw failure("Manifest document must not be empty.", path: "$")
            }
            try checkCancellation(cancellationCheck)
            var traversal = NodeTraversal(cancellationCheck: cancellationCheck)
            try traversal.inspect(root, path: "$", depth: 1)
            try checkCancellation(cancellationCheck)
            return try ManifestNodeDecoder().decode(root)
        } catch let error as ManifestParseError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as YamlError {
            throw ManifestParseError.failed([issue(for: error)])
        } catch {
            throw failure("YAML parsing failed: \(String(describing: error))", path: "$")
        }
    }

    private static func checkCancellation(_ cancellationCheck: @Sendable () -> Bool) throws {
        if cancellationCheck() {
            throw CancellationError()
        }
    }

    private static func preflightDepth(_ text: String) throws {
        var indentationStack = [0]
        for (offset, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indentation = line.prefix { $0 == " " }.count
            while indentation < (indentationStack.last ?? 0), indentationStack.count > 1 {
                indentationStack.removeLast()
            }
            if indentation > (indentationStack.last ?? 0) {
                indentationStack.append(indentation)
            }

            var flowDepth = 0
            var quote: Character?
            var escaping = false
            for character in trimmed {
                if escaping {
                    escaping = false
                    continue
                }
                if quote == "\"" && character == "\\" {
                    escaping = true
                    continue
                }
                if let activeQuote = quote {
                    if character == activeQuote {
                        quote = nil
                    }
                    continue
                }
                if character == "\"" || character == "'" {
                    quote = character
                } else if character == "#" {
                    break
                } else if character == "[" || character == "{" {
                    flowDepth += 1
                } else if character == "]" || character == "}" {
                    flowDepth = max(0, flowDepth - 1)
                }
                if indentationStack.count + flowDepth > maximumDepth {
                    throw ManifestParseError.failed([
                        ManifestIssue(
                            code: .manifestUnsupportedFeature,
                            message: "Manifest nesting exceeds the maximum depth of \(maximumDepth).",
                            line: offset + 1,
                            column: indentation + 1,
                            path: "$"
                        )
                    ])
                }
            }
        }
    }

    private static func issue(for error: YamlError) -> ManifestIssue {
        switch error {
        case .duplicatedKeysInMapping(let duplicates, let context):
            let message: String
            if duplicates == ["imagePolicy"] {
                message = "Manifest imagePolicy must be declared at most once."
            } else if duplicates == ["imageSBOM"] {
                message = "Manifest imageSBOM must be declared at most once."
            } else if duplicates == ["imageTrust"] {
                message = "Manifest imageTrust must be declared at most once."
            } else if duplicates == ["imageVulnerability"] {
                message = "Manifest imageVulnerability must be declared at most once."
            } else if duplicates == ["imageProvenance"] {
                message = "Manifest imageProvenance must be declared at most once."
            } else if duplicates == ["version"] {
                message = "Manifest version must be declared at most once."
            } else {
                message = "Mapping keys must be unique; duplicate keys: \(duplicates.sorted().joined(separator: ", "))."
            }
            return ManifestIssue(
                code: .manifestValidationFailed,
                message: message,
                line: context.mark.line,
                column: context.mark.column,
                path: "$"
            )
        case .scanner(_, let problem, let mark, _),
             .parser(_, let problem, let mark, _),
             .composer(_, let problem, let mark, _):
            return ManifestIssue(
                code: .manifestParseFailed,
                message: "Invalid YAML: \(problem).",
                line: mark.line,
                column: mark.column,
                path: "$"
            )
        case .reader(let problem, _, _, _):
            return ManifestIssue(code: .manifestParseFailed, message: "Invalid UTF-8 YAML: \(problem).", path: "$")
        default:
            return ManifestIssue(
                code: .manifestParseFailed,
                message: "YAML parsing failed: \(error.description).",
                path: "$"
            )
        }
    }

    fileprivate static func failure(
        _ message: String,
        code: HostwrightErrorCode = .manifestParseFailed,
        node: Node? = nil,
        path: String
    ) -> ManifestParseError {
        ManifestParseError.failed([
            ManifestIssue(
                code: code,
                message: message,
                line: node?.mark?.line,
                column: node?.mark?.column,
                path: path
            )
        ])
    }
}

private struct NodeTraversal {
    private var count = 0
    let cancellationCheck: @Sendable () -> Bool

    init(cancellationCheck: @escaping @Sendable () -> Bool) {
        self.cancellationCheck = cancellationCheck
    }

    mutating func inspect(_ node: Node, path: String, depth: Int) throws {
        guard depth <= ManifestParser.maximumDepth else {
            throw ManifestParser.failure(
                "Manifest nesting exceeds the maximum depth of \(ManifestParser.maximumDepth).",
                code: .manifestUnsupportedFeature,
                node: node,
                path: path
            )
        }
        count += 1
        if count.isMultiple(of: 1_024), cancellationCheck() {
            throw CancellationError()
        }
        guard count <= ManifestParser.maximumExpandedNodes else {
            throw ManifestParser.failure(
                "Manifest exceeds the maximum expanded node count of \(ManifestParser.maximumExpandedNodes).",
                code: .manifestUnsupportedFeature,
                node: node,
                path: path
            )
        }
        guard node.anchor == nil else {
            throw ManifestParser.failure(
                "YAML anchors and aliases are not supported.",
                code: .manifestUnsupportedFeature,
                node: node,
                path: path
            )
        }
        try rejectCustomTag(node, path: path)

        switch node {
        case .scalar:
            return
        case .alias:
            throw ManifestParser.failure(
                "YAML aliases are not supported.",
                code: .manifestUnsupportedFeature,
                node: node,
                path: path
            )
        case .sequence(let sequence):
            for (index, child) in sequence.enumerated() {
                try inspect(child, path: "\(path)[\(index)]", depth: depth + 1)
            }
        case .mapping(let mapping):
            for pair in mapping {
                if pair.key.tag.rawValue == Tag.Name.merge.rawValue || pair.key.string == "<<" {
                    throw ManifestParser.failure(
                        "YAML merge keys are not supported.",
                        code: .manifestUnsupportedFeature,
                        node: pair.key,
                        path: path
                    )
                }
                try inspect(pair.key, path: path, depth: depth + 1)
                let component = pair.key.scalar?.string ?? "?"
                try inspect(pair.value, path: "\(path).\(component)", depth: depth + 1)
            }
        }
    }

    private func rejectCustomTag(_ node: Node, path: String) throws {
        let raw: String
        switch node {
        case .scalar(let scalar): raw = scalar.tag.rawValue
        case .mapping(let mapping): raw = mapping.tag.rawValue
        case .sequence(let sequence): raw = sequence.tag.rawValue
        case .alias(let alias): raw = alias.tag.rawValue
        }
        let standard = [
            "",
            "!",
            Tag.Name.str.rawValue,
            Tag.Name.seq.rawValue,
            Tag.Name.map.rawValue,
            Tag.Name.bool.rawValue,
            Tag.Name.int.rawValue,
            Tag.Name.float.rawValue,
            Tag.Name.null.rawValue
        ]
        guard standard.contains(raw) else {
            throw ManifestParser.failure(
                "Custom YAML tag '\(raw)' is not supported.",
                code: .manifestUnsupportedFeature,
                node: node,
                path: path
            )
        }
    }
}

private struct ManifestNodeDecoder {
    func decode(_ root: Node) throws -> HostwrightManifest {
        let values = try mapping(
            root,
            path: "$",
            allowed: [
                "version", "project", "imagePolicy", "imageTrust", "imageSBOM",
                "imageVulnerability", "imageProvenance", "volumes", "networks",
                "services"
            ]
        )
        let version = try values["version"].map(versionInteger)
        let project = try values["project"].map { try string($0, path: "$.project") }
        let imagePolicy = try values["imagePolicy"].map { node -> HostwrightImagePolicy in
            let raw = try string(node, path: "$.imagePolicy")
            guard let value = HostwrightImagePolicy(rawValue: raw) else {
                throw ManifestParser.failure(
                    "Manifest imagePolicy must be one of: allow-tags, require-digest.",
                    code: .manifestValidationFailed,
                    node: node,
                    path: "$.imagePolicy"
                )
            }
            return value
        }
        let imageTrust = try values["imageTrust"].map {
            try decodeImageTrust($0, path: "$.imageTrust")
        }
        let imageSBOM = try values["imageSBOM"].map {
            try decodeImageSBOM($0, path: "$.imageSBOM")
        }
        let imageVulnerability = try values["imageVulnerability"].map {
            try decodeImageVulnerability($0, path: "$.imageVulnerability")
        }
        let imageProvenance = try values["imageProvenance"].map {
            try decodeImageProvenance($0, path: "$.imageProvenance")
        }
        let volumes = try values["volumes"].map {
            try decodeVolumeDeclarations($0, path: "$.volumes")
        } ?? [:]
        let networks = try values["networks"].map {
            try decodeNetworkDefinitions($0, path: "$.networks")
        } ?? [:]
        let services = try values["services"].map(decodeServices) ?? []
        return HostwrightManifest(
            version: version,
            project: project,
            imagePolicy: imagePolicy,
            imageTrust: imageTrust,
            imageSBOM: imageSBOM,
            imageVulnerability: imageVulnerability,
            imageProvenance: imageProvenance,
            volumes: volumes,
            networks: networks,
            services: services
        )
    }

    private func decodeNetworkDefinitions(
        _ node: Node,
        path: String
    ) throws -> [String: HostwrightNetworkDefinition] {
        var result: [String: HostwrightNetworkDefinition] = [:]
        for pair in try rawMapping(node, path: path) {
            let name = try keyString(pair.key, path: path)
            let definitionPath = "\(path).\(name)"
            let values = try mapping(
                pair.value,
                path: definitionPath,
                allowed: ["driver", "ipv4", "ipv6"]
            )
            let driverRaw = try values["driver"].map {
                try string($0, path: "\(definitionPath).driver")
            } ?? HostwrightNetworkDriver.nat.rawValue
            guard let driver = HostwrightNetworkDriver(rawValue: driverRaw) else {
                throw ManifestParser.failure(
                    "Network driver must be one of: nat, hostOnly.",
                    code: .manifestValidationFailed,
                    node: values["driver"],
                    path: "\(definitionPath).driver"
                )
            }
            let ipv4 = try decodeNetworkAddressRequest(
                values["ipv4"],
                default: .auto,
                ipv6: false,
                path: "\(definitionPath).ipv4"
            )
            let ipv6 = try decodeNetworkAddressRequest(
                values["ipv6"],
                default: .auto,
                ipv6: true,
                path: "\(definitionPath).ipv6"
            )
            result[name] = HostwrightNetworkDefinition(
                name: name,
                driver: driver,
                ipv4: ipv4,
                ipv6: ipv6
            )
        }
        return result
    }

    private func decodeNetworkAddressRequest(
        _ node: Node?,
        default defaultValue: HostwrightNetworkAddressRequest,
        ipv6: Bool,
        path: String
    ) throws -> HostwrightNetworkAddressRequest {
        guard let node else { return defaultValue }
        let raw = try string(node, path: path)
        guard let value = HostwrightNetworkAddressRequest(manifestValue: raw) else {
            throw ManifestParser.failure(
                "Network address request must be auto, disabled, or a CIDR.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        if case .cidr(let cidr) = value,
           let normalized = ManifestValidator.normalizedNetworkCIDR(cidr, ipv6: ipv6) {
            return .cidr(normalized)
        }
        return value
    }

    private func decodeVolumeDeclarations(
        _ node: Node,
        path: String
    ) throws -> [String: HostwrightVolumeDeclaration] {
        var result: [String: HostwrightVolumeDeclaration] = [:]
        for pair in try rawMapping(node, path: path) {
            let name = try keyString(pair.key, path: path)
            result[name] = try decodeVolumeDeclaration(pair.value, path: "\(path).\(name)")
        }
        return result
    }

    private func decodeVolumeDeclaration(
        _ node: Node,
        path: String
    ) throws -> HostwrightVolumeDeclaration {
        let values = try mapping(
            node,
            path: path,
            allowed: ["provider", "capacity", "accessMode", "reclaimPolicy", "labels"]
        )
        let provider = try values["provider"].map { try string($0, path: "\(path).provider") }
            ?? HostwrightVolumeDeclaration.defaultProvider
        let capacity = try requiredString(
            values["capacity"],
            path: "\(path).capacity",
            message: "Volume capacity is required."
        )
        let accessModeRaw = try values["accessMode"].map { try string($0, path: "\(path).accessMode") }
            ?? HostwrightVolumeAccessMode.readWriteOnce.rawValue
        guard let accessMode = HostwrightVolumeAccessMode(rawValue: accessModeRaw) else {
            throw ManifestParser.failure(
                "Volume accessMode must be read-write-once or read-only-many.",
                code: .manifestValidationFailed,
                node: values["accessMode"],
                path: "\(path).accessMode"
            )
        }
        let reclaimPolicyRaw = try values["reclaimPolicy"].map { try string($0, path: "\(path).reclaimPolicy") }
            ?? HostwrightVolumeReclaimPolicy.retain.rawValue
        guard let reclaimPolicy = HostwrightVolumeReclaimPolicy(rawValue: reclaimPolicyRaw) else {
            throw ManifestParser.failure(
                "Volume reclaimPolicy must be retain, delete, snapshot-before-delete, backup-before-delete, or recycle.",
                code: .manifestValidationFailed,
                node: values["reclaimPolicy"],
                path: "\(path).reclaimPolicy"
            )
        }
        let labels = try values["labels"].map { try stringMap($0, path: "\(path).labels") } ?? [:]
        return HostwrightVolumeDeclaration(
            provider: provider,
            capacity: capacity,
            accessMode: accessMode,
            reclaimPolicy: reclaimPolicy,
            labels: labels
        )
    }

    private func decodeImageTrust(
        _ node: Node,
        path: String
    ) throws -> HostwrightImageTrustPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["version", "threshold", "trustedRoot", "authorities"]
        )
        let version = try values["version"].map { try integer($0, path: "\(path).version") }
            ?? HostwrightImageTrustPolicy.currentVersion
        let threshold = try requiredInteger(
            values["threshold"],
            path: "\(path).threshold",
            message: "imageTrust.threshold is required."
        )
        let trustedRoot = try values["trustedRoot"].map {
            try string($0, path: "\(path).trustedRoot")
        }
        let authorities = try decodeImageTrustAuthorities(
            values["authorities"],
            path: "\(path).authorities"
        )
        return HostwrightImageTrustPolicy(
            version: version,
            threshold: threshold,
            trustedRoot: trustedRoot,
            authorities: authorities
        )
    }

    private func decodeImageTrustAuthorities(
        _ node: Node?,
        path: String
    ) throws -> [HostwrightImageTrustAuthority] {
        guard let node else {
            throw ManifestParser.failure(
                "imageTrust.authorities is required.",
                code: .manifestValidationFailed,
                path: path
            )
        }
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }
        return try sequence.enumerated().map { index, child in
            try decodeImageTrustAuthority(child, path: "\(path)[\(index)]")
        }.sorted { $0.id < $1.id }
    }

    private func decodeImageTrustAuthority(
        _ node: Node,
        path: String
    ) throws -> HostwrightImageTrustAuthority {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "id", "type", "publicKey", "issuer", "identity",
                "notBefore", "notAfter", "revokedAt"
            ]
        )
        let id = try requiredString(
            values["id"],
            path: "\(path).id",
            message: "imageTrust authority id is required."
        )
        let type = try requiredAuthorityType(
            values["type"],
            path: "\(path).type"
        )
        return HostwrightImageTrustAuthority(
            id: id,
            type: type,
            publicKey: try values["publicKey"].map { try string($0, path: "\(path).publicKey") },
            issuer: try values["issuer"].map { try string($0, path: "\(path).issuer") },
            identity: try values["identity"].map { try string($0, path: "\(path).identity") },
            notBefore: try values["notBefore"].map { try string($0, path: "\(path).notBefore") },
            notAfter: try values["notAfter"].map { try string($0, path: "\(path).notAfter") },
            revokedAt: try values["revokedAt"].map { try string($0, path: "\(path).revokedAt") }
        )
    }

    private func decodeImageSBOM(
        _ node: Node,
        path: String
    ) throws -> HostwrightImageSBOMPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["version", "requirement", "formats"]
        )
        let version = try values["version"].map { try integer($0, path: "\(path).version") }
            ?? HostwrightImageSBOMPolicy.currentVersion
        let requirement = try requiredImageSBOMRequirement(
            values["requirement"],
            path: "\(path).requirement"
        )
        let formats = try decodeImageSBOMFormats(
            values["formats"],
            path: "\(path).formats"
        )
        return HostwrightImageSBOMPolicy(
            version: version,
            requirement: requirement,
            formats: formats
        )
    }

    private func decodeImageSBOMFormats(
        _ node: Node?,
        path: String
    ) throws -> [HostwrightImageSBOMFormat] {
        guard let node else {
            throw ManifestParser.failure(
                "imageSBOM.formats is required.",
                code: .manifestValidationFailed,
                path: path
            )
        }
        let values = try strings(node, path: path)
        return try values.map { raw in
            guard let format = HostwrightImageSBOMFormat(rawValue: raw) else {
                throw ManifestParser.failure(
                    "imageSBOM.formats must be one of: spdx-json, cyclonedx-json.",
                    code: .manifestValidationFailed,
                    path: path
                )
            }
            return format
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private func decodeImageVulnerability(
        _ node: Node,
        path: String
    ) throws -> HostwrightImageVulnerabilityPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "version", "severityThreshold", "minimumVulnerabilityAgeSeconds",
                "exploitability", "fixAvailability", "maximumDatabaseAgeSeconds",
                "staleAction", "unavailableAction", "exceptionApproval", "allowlist"
            ]
        )
        let version = try values["version"].map { try integer($0, path: "\(path).version") }
            ?? HostwrightImageVulnerabilityPolicy.currentVersion
        let severityThreshold = try requiredImageVulnerabilityEnum(
            values["severityThreshold"],
            path: "\(path).severityThreshold",
            message: "imageVulnerability.severityThreshold is required.",
            allowed: HostwrightVulnerabilitySeverity.self,
            allowedValues: "low, medium, high, critical"
        )
        let minimumVulnerabilityAgeSeconds = try requiredInteger(
            values["minimumVulnerabilityAgeSeconds"],
            path: "\(path).minimumVulnerabilityAgeSeconds",
            message: "imageVulnerability.minimumVulnerabilityAgeSeconds is required."
        )
        let exploitability = try requiredImageVulnerabilityEnum(
            values["exploitability"],
            path: "\(path).exploitability",
            message: "imageVulnerability.exploitability is required.",
            allowed: HostwrightVulnerabilityExploitability.self,
            allowedValues: "any, known-exploited"
        )
        let fixAvailability = try requiredImageVulnerabilityEnum(
            values["fixAvailability"],
            path: "\(path).fixAvailability",
            message: "imageVulnerability.fixAvailability is required.",
            allowed: HostwrightVulnerabilityFixAvailability.self,
            allowedValues: "any, fix-available"
        )
        let maximumDatabaseAgeSeconds = try requiredInteger(
            values["maximumDatabaseAgeSeconds"],
            path: "\(path).maximumDatabaseAgeSeconds",
            message: "imageVulnerability.maximumDatabaseAgeSeconds is required."
        )
        let staleAction = try requiredImageVulnerabilityEnum(
            values["staleAction"],
            path: "\(path).staleAction",
            message: "imageVulnerability.staleAction is required.",
            allowed: HostwrightVulnerabilityDataAction.self,
            allowedValues: "fail-open, fail-closed"
        )
        let unavailableAction = try requiredImageVulnerabilityEnum(
            values["unavailableAction"],
            path: "\(path).unavailableAction",
            message: "imageVulnerability.unavailableAction is required.",
            allowed: HostwrightVulnerabilityDataAction.self,
            allowedValues: "fail-open, fail-closed"
        )
        let exceptionApproval = try requiredImageVulnerabilityEnum(
            values["exceptionApproval"],
            path: "\(path).exceptionApproval",
            message: "imageVulnerability.exceptionApproval is required.",
            allowed: HostwrightVulnerabilityExceptionApprovalMode.self,
            allowedValues: "required, disabled"
        )
        let allowlist = try decodeImageVulnerabilityAllowlist(
            values["allowlist"],
            path: "\(path).allowlist"
        )
        return HostwrightImageVulnerabilityPolicy(
            version: version,
            severityThreshold: severityThreshold,
            minimumVulnerabilityAgeSeconds: minimumVulnerabilityAgeSeconds,
            exploitability: exploitability,
            fixAvailability: fixAvailability,
            maximumDatabaseAgeSeconds: maximumDatabaseAgeSeconds,
            staleAction: staleAction,
            unavailableAction: unavailableAction,
            exceptionApproval: exceptionApproval,
            allowlist: allowlist
        )
    }

    private func decodeImageVulnerabilityAllowlist(
        _ node: Node?,
        path: String
    ) throws -> [HostwrightImageVulnerabilityAllowlistEntry] {
        guard let node else {
            return []
        }
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }
        return try sequence.enumerated().map { index, child in
            let entryPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: entryPath,
                allowed: ["vulnerabilityID", "packagePURL", "reason", "expiresAt"]
            )
            return HostwrightImageVulnerabilityAllowlistEntry(
                vulnerabilityID: try requiredString(
                    values["vulnerabilityID"],
                    path: "\(entryPath).vulnerabilityID",
                    message: "imageVulnerability allowlist vulnerabilityID is required."
                ),
                packagePURL: try values["packagePURL"].map {
                    try string($0, path: "\(entryPath).packagePURL")
                },
                reason: try requiredString(
                    values["reason"],
                    path: "\(entryPath).reason",
                    message: "imageVulnerability allowlist reason is required."
                ),
                expiresAt: try requiredString(
                    values["expiresAt"],
                    path: "\(entryPath).expiresAt",
                    message: "imageVulnerability allowlist expiresAt is required."
                )
            )
        }.sorted(by: imageVulnerabilityAllowlistPrecedes)
    }

    private func imageVulnerabilityAllowlistPrecedes(
        _ lhs: HostwrightImageVulnerabilityAllowlistEntry,
        _ rhs: HostwrightImageVulnerabilityAllowlistEntry
    ) -> Bool {
        if lhs.vulnerabilityID != rhs.vulnerabilityID {
            return lhs.vulnerabilityID < rhs.vulnerabilityID
        }
        if lhs.packagePURL != rhs.packagePURL {
            return (lhs.packagePURL ?? "") < (rhs.packagePURL ?? "")
        }
        if lhs.expiresAt != rhs.expiresAt {
            return lhs.expiresAt < rhs.expiresAt
        }
        return lhs.reason < rhs.reason
    }

    private func decodeImageProvenance(
        _ node: Node,
        path: String
    ) throws -> HostwrightImageProvenancePolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "version", "requirement", "builderIDs", "buildTypes", "signers",
                "maximumAgeSeconds", "requireReproducible"
            ]
        )
        let version = try values["version"].map { try integer($0, path: "\(path).version") }
            ?? HostwrightImageProvenancePolicy.currentVersion
        let requirement = try requiredImageProvenanceRequirement(
            values["requirement"],
            path: "\(path).requirement"
        )
        let builderIDs = try requiredStrings(
            values["builderIDs"],
            path: "\(path).builderIDs",
            message: "imageProvenance.builderIDs is required."
        ).sorted()
        let buildTypes = try requiredStrings(
            values["buildTypes"],
            path: "\(path).buildTypes",
            message: "imageProvenance.buildTypes is required."
        ).sorted()
        let signers = try decodeImageProvenanceSigners(
            values["signers"],
            path: "\(path).signers"
        )
        let maximumAgeSeconds = try requiredInteger(
            values["maximumAgeSeconds"],
            path: "\(path).maximumAgeSeconds",
            message: "imageProvenance.maximumAgeSeconds is required."
        )
        let requireReproducible = try requiredBoolean(
            values["requireReproducible"],
            path: "\(path).requireReproducible",
            message: "imageProvenance.requireReproducible is required."
        )
        return HostwrightImageProvenancePolicy(
            version: version,
            requirement: requirement,
            builderIDs: builderIDs,
            buildTypes: buildTypes,
            signers: signers,
            maximumAgeSeconds: maximumAgeSeconds,
            requireReproducible: requireReproducible
        )
    }

    private func decodeImageProvenanceSigners(
        _ node: Node?,
        path: String
    ) throws -> [HostwrightImageProvenanceSigner] {
        guard let node else {
            throw ManifestParser.failure(
                "imageProvenance.signers is required.",
                code: .manifestValidationFailed,
                path: path
            )
        }
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }
        return try sequence.enumerated().map { index, child in
            let signerPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: signerPath,
                allowed: ["id", "publicKey", "notBefore", "notAfter", "revokedAt"]
            )
            return HostwrightImageProvenanceSigner(
                id: try requiredString(
                    values["id"],
                    path: "\(signerPath).id",
                    message: "imageProvenance signer id is required."
                ),
                publicKey: try requiredString(
                    values["publicKey"],
                    path: "\(signerPath).publicKey",
                    message: "imageProvenance signer publicKey is required."
                ),
                notBefore: try values["notBefore"].map {
                    try string($0, path: "\(signerPath).notBefore")
                },
                notAfter: try values["notAfter"].map {
                    try string($0, path: "\(signerPath).notAfter")
                },
                revokedAt: try values["revokedAt"].map {
                    try string($0, path: "\(signerPath).revokedAt")
                }
            )
        }.sorted { $0.id < $1.id }
    }

    private func decodeServices(_ node: Node) throws -> [HostwrightService] {
        let pairs = try rawMapping(node, path: "$.services")
        var services: [HostwrightService] = []
        services.reserveCapacity(pairs.count)
        for pair in pairs {
            let name = try keyString(pair.key, path: "$.services")
            services.append(try decodeService(name: name, node: pair.value, path: "$.services.\(name)"))
        }
        return services.sorted { $0.name < $1.name }
    }

    private func decodeService(name: String, node: Node, path: String) throws -> HostwrightService {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "image", "replicas", "platform", "resources", "user", "group", "workdir",
                "entrypoint", "command", "init", "dependsOn", "env", "secretEnv", "labels",
                "ports", "networks", "volumes", "health", "probes", "restart", "update", "hooks",
                "rosetta", "virtualization", "readOnlyRootFilesystem", "shmSize"
            ]
        )

        let image = try values["image"].map { try string($0, path: "\(path).image") }
        let replicas = try values["replicas"].map { try integer($0, path: "\(path).replicas") } ?? 1
        let platform = try values["platform"].map { try decodePlatform($0, path: "\(path).platform") } ?? HostwrightPlatform()
        let resources = try values["resources"].map { try decodeResources($0, path: "\(path).resources") }
        let user = try values["user"].map { try unsignedID($0, path: "\(path).user") }
        let group = try values["group"].map { try unsignedID($0, path: "\(path).group") }
        let workdir = try values["workdir"].map { try string($0, path: "\(path).workdir") }
        let entrypoint = try values["entrypoint"].map { try strings($0, path: "\(path).entrypoint") } ?? []
        let command = try values["command"].map { try strings($0, path: "\(path).command") } ?? []
        let initProcess = try values["init"].map { try boolean($0, path: "\(path).init") } ?? false
        let dependsOn = try values["dependsOn"].map { try dependencies($0, path: "\(path).dependsOn") } ?? [:]
        let env = try values["env"].map { try stringMap($0, path: "\(path).env") } ?? [:]
        let secretEnv = try values["secretEnv"].map { try secrets($0, path: "\(path).secretEnv") } ?? [:]
        let labels = try values["labels"].map { try stringMap($0, path: "\(path).labels") } ?? [:]
        let publishedPorts = try values["ports"].map { try decodePublishedPorts($0, path: "\(path).ports") } ?? []
        let ports = publishedPorts.compactMap(\.canonicalLegacyLiteral)
        let networks = try values["networks"].map {
            try decodeServiceNetworks($0, path: "\(path).networks")
        } ?? []
        let decodedVolumes = try values["volumes"].map { try decodeMounts($0, path: "\(path).volumes") }
        let volumes = decodedVolumes?.legacyVolumes ?? []
        let mounts = decodedVolumes?.mounts ?? []
        let legacyHealth = try values["health"].map { try health($0, path: "\(path).health") }
        var probes = try values["probes"].map { try decodeProbes($0, path: "\(path).probes") } ?? HostwrightProbes()
        if let legacyHealth {
            guard probes.liveness == nil else {
                throw ManifestParser.failure(
                    "health and probes.liveness cannot both be declared.",
                    code: .manifestValidationFailed,
                    node: values["health"],
                    path: path
                )
            }
            probes.liveness = HostwrightProbe(
                action: .exec(legacyHealth.command),
                interval: try seconds(legacyHealth.interval ?? "10s", node: values["health"], path: "\(path).health.interval")
            )
        }
        let projectedHealth = execHealth(from: probes.liveness)
        let restart = try values["restart"].map { try decodeRestart($0, path: "\(path).restart") }
        let update = try values["update"].map { try decodeUpdate($0, path: "\(path).update") } ?? HostwrightUpdatePolicy()
        let hooks = try values["hooks"].map { try decodeHooks($0, path: "\(path).hooks") } ?? HostwrightHooks()
        let rosetta = try values["rosetta"].map { try boolean($0, path: "\(path).rosetta") } ?? false
        let virtualization = try values["virtualization"].map { try boolean($0, path: "\(path).virtualization") } ?? false
        let readOnlyRoot = try values["readOnlyRootFilesystem"].map {
            try boolean($0, path: "\(path).readOnlyRootFilesystem")
        } ?? false
        let shmSize = try values["shmSize"].map { try string($0, path: "\(path).shmSize") }

        return HostwrightService(
            name: name,
            image: image,
            replicas: replicas,
            platform: platform,
            resources: resources,
            user: user,
            group: group,
            workdir: workdir,
            entrypoint: entrypoint,
            command: command,
            initProcess: initProcess,
            dependsOn: dependsOn,
            env: env,
            secretEnv: secretEnv,
            labels: labels,
            ports: ports,
            publishedPorts: publishedPorts,
            networks: networks,
            volumes: volumes,
            mounts: mounts,
            probes: probes,
            health: projectedHealth,
            restart: restart,
            update: update,
            hooks: hooks,
            rosetta: rosetta,
            virtualization: virtualization,
            readOnlyRootFilesystem: readOnlyRoot,
            shmSize: shmSize
        )
    }

    private func decodePublishedPorts(
        _ node: Node,
        path: String
    ) throws -> [HostwrightPublishedPort] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }

        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            switch child {
            case .scalar:
                let literal = try string(child, path: itemPath)
                guard let publishedPort = HostwrightPublishedPort.legacy(literal) else {
                    throw ManifestParser.failure(
                        "Port must use legacy \"host:container\" or a structured mapping.",
                        node: child,
                        path: itemPath
                    )
                }
                return publishedPort

            case .mapping:
                let values = try mapping(
                    child,
                    path: itemPath,
                    allowed: ["bind", "host", "protocol", "target"]
                )
                let target = try decodePortSpan(
                    values["target"],
                    path: "\(itemPath).target",
                    message: "Structured port mapping requires target."
                )
                let host = try values["host"].map { try decodePortSpanValue($0, path: "\(itemPath).host") }
                let protocolName = try values["protocol"].map {
                    try decodePortProtocol($0, path: "\(itemPath).protocol")
                } ?? .tcp
                let bindAddress = try values["bind"].map { try string($0, path: "\(itemPath).bind") }

                return HostwrightPublishedPort(
                    host: host,
                    target: target,
                    protocolName: protocolName,
                    bindAddress: bindAddress ?? HostwrightPublishedPort.localhostBindAddress
                )

            default:
                throw ManifestParser.failure(
                    "Port must use legacy \"host:container\" or a structured mapping.",
                    node: child,
                    path: itemPath
                )
            }
        }
    }

    private func decodePortSpan(
        _ node: Node?,
        path: String,
        message: String
    ) throws -> HostwrightPortSpan {
        guard let node else {
            throw ManifestParser.failure(message, code: .manifestValidationFailed, path: path)
        }
        return try decodePortSpanValue(node, path: path)
    }

    private func decodePortSpanValue(
        _ node: Node,
        path: String
    ) throws -> HostwrightPortSpan {
        guard case .scalar(let scalar) = node else {
            throw ManifestParser.failure(
                "Port must be an integer or a range string like \"8000-8003\".",
                node: node,
                path: path
            )
        }
        if node.tag.rawValue == Tag.Name.int.rawValue {
            guard let port = Int(scalar.string) else {
                throw ManifestParser.failure("Port exceeds supported integer range.", node: node, path: path)
            }
            return HostwrightPortSpan(start: port)
        }
        guard node.tag.rawValue == Tag.Name.str.rawValue,
              let span = parsePortSpan(scalar.string) else {
            throw ManifestParser.failure(
                "Port must be an integer or a range string like \"8000-8003\".",
                node: node,
                path: path
            )
        }
        return span
    }

    private func decodePortProtocol(
        _ node: Node,
        path: String
    ) throws -> HostwrightPortProtocol {
        let value = try string(node, path: path)
        guard let protocolName = HostwrightPortProtocol(rawValue: value) else {
            throw ManifestParser.failure(
                "protocol must be one of: tcp, udp.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return protocolName
    }

    private func parsePortSpan(_ value: String) -> HostwrightPortSpan? {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        switch fields.count {
        case 1:
            guard let port = Int(fields[0]) else { return nil }
            return HostwrightPortSpan(start: port)
        case 2:
            guard let start = Int(fields[0]),
                  let end = Int(fields[1]) else {
                return nil
            }
            return HostwrightPortSpan(start: start, end: end)
        default:
            return nil
        }
    }

    private func decodeServiceNetworks(
        _ node: Node,
        path: String
    ) throws -> [HostwrightServiceNetworkAttachment] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }

        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            if case .scalar = child {
                return HostwrightServiceNetworkAttachment(
                    network: try string(child, path: itemPath)
                )
            }

            let values = try mapping(
                child,
                path: itemPath,
                allowed: ["network", "aliases"]
            )
            let network = try requiredString(
                values["network"],
                path: "\(itemPath).network",
                message: "Service network attachment requires network."
            )
            let aliases = try values["aliases"].map {
                try strings($0, path: "\(itemPath).aliases")
            } ?? []
            return HostwrightServiceNetworkAttachment(
                network: network,
                aliases: aliases.sorted()
            )
        }
        .sorted {
            if $0.network != $1.network {
                return $0.network < $1.network
            }
            return $0.aliases.lexicographicallyPrecedes($1.aliases)
        }
    }

    private func decodePlatform(_ node: Node, path: String) throws -> HostwrightPlatform {
        let values = try mapping(node, path: path, allowed: ["os", "architecture"])
        let osRaw = try values["os"].map { try string($0, path: "\(path).os") } ?? HostwrightPlatformOS.linux.rawValue
        let archRaw = try values["architecture"].map {
            try string($0, path: "\(path).architecture")
        } ?? HostwrightArchitecture.arm64.rawValue
        guard let os = HostwrightPlatformOS(rawValue: osRaw) else {
            throw ManifestParser.failure(
                "platform.os must be linux.",
                code: .manifestValidationFailed,
                node: values["os"],
                path: "\(path).os"
            )
        }
        guard let architecture = HostwrightArchitecture(rawValue: archRaw) else {
            throw ManifestParser.failure(
                "platform.architecture must be arm64 or amd64.",
                code: .manifestValidationFailed,
                node: values["architecture"],
                path: "\(path).architecture"
            )
        }
        return HostwrightPlatform(os: os, architecture: architecture)
    }

    private func decodeResources(_ node: Node, path: String) throws -> HostwrightResources {
        let values = try mapping(node, path: path, allowed: ["cpus", "memory"])
        return HostwrightResources(
            cpus: try values["cpus"].map { try integer($0, path: "\(path).cpus") },
            memory: try values["memory"].map { try string($0, path: "\(path).memory") }
        )
    }

    private func dependencies(_ node: Node, path: String) throws -> [String: HostwrightDependencyCondition] {
        var result: [String: HostwrightDependencyCondition] = [:]
        for pair in try rawMapping(node, path: path) {
            let key = try keyString(pair.key, path: path)
            let raw = try string(pair.value, path: "\(path).\(key)")
            guard let condition = HostwrightDependencyCondition(rawValue: raw) else {
                throw ManifestParser.failure(
                    "Dependency condition must be started, ready, or completed.",
                    code: .manifestValidationFailed,
                    node: pair.value,
                    path: "\(path).\(key)"
                )
            }
            result[key] = condition
        }
        return result
    }

    private func decodeProbes(_ node: Node, path: String) throws -> HostwrightProbes {
        let values = try mapping(node, path: path, allowed: ["startup", "readiness", "liveness"])
        return HostwrightProbes(
            startup: try values["startup"].map { try decodeProbe($0, path: "\(path).startup") },
            readiness: try values["readiness"].map { try decodeProbe($0, path: "\(path).readiness") },
            liveness: try values["liveness"].map { try decodeProbe($0, path: "\(path).liveness") }
        )
    }

    private func decodeProbe(_ node: Node, path: String) throws -> HostwrightProbe {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "exec", "http", "tcp", "startPeriod", "interval", "timeout",
                "successThreshold", "failureThreshold"
            ]
        )
        let actions = ["exec", "http", "tcp"].compactMap { key in values[key].map { (key, $0) } }
        guard actions.count == 1, let selected = actions.first else {
            throw ManifestParser.failure(
                "Probe must declare exactly one action: exec, http, or tcp.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        let action: HostwrightProbeAction
        switch selected.0 {
        case "exec":
            action = .exec(try strings(selected.1, path: "\(path).exec"))
        case "http":
            let http = try mapping(selected.1, path: "\(path).http", allowed: ["port", "path"])
            guard let portNode = http["port"] else {
                throw ManifestParser.failure("HTTP probe requires port.", node: selected.1, path: "\(path).http.port")
            }
            action = .http(
                port: try integer(portNode, path: "\(path).http.port"),
                path: try http["path"].map { try string($0, path: "\(path).http.path") } ?? "/"
            )
        default:
            let tcp = try mapping(selected.1, path: "\(path).tcp", allowed: ["port"])
            guard let portNode = tcp["port"] else {
                throw ManifestParser.failure("TCP probe requires port.", node: selected.1, path: "\(path).tcp.port")
            }
            action = .tcp(port: try integer(portNode, path: "\(path).tcp.port"))
        }
        return HostwrightProbe(
            action: action,
            startPeriod: try duration(values["startPeriod"], default: 0, path: "\(path).startPeriod"),
            interval: try duration(values["interval"], default: 10, path: "\(path).interval"),
            timeout: try duration(values["timeout"], default: 3, path: "\(path).timeout"),
            successThreshold: try values["successThreshold"].map {
                try integer($0, path: "\(path).successThreshold")
            } ?? 1,
            failureThreshold: try values["failureThreshold"].map {
                try integer($0, path: "\(path).failureThreshold")
            } ?? 3
        )
    }

    private func health(_ node: Node, path: String) throws -> HostwrightHealthCheck {
        let values = try mapping(node, path: path, allowed: ["command", "interval"])
        return HostwrightHealthCheck(
            command: try values["command"].map { try strings($0, path: "\(path).command") } ?? [],
            interval: try values["interval"].map { try string($0, path: "\(path).interval") }
        )
    }

    private func execHealth(from probe: HostwrightProbe?) -> HostwrightHealthCheck? {
        guard let probe, case .exec(let command) = probe.action else { return nil }
        return HostwrightHealthCheck(command: command, interval: "\(probe.interval)s")
    }

    private func decodeRestart(_ node: Node, path: String) throws -> HostwrightRestart {
        let values = try mapping(node, path: path, allowed: ["policy"])
        guard let policy = values["policy"] else {
            throw ManifestParser.failure("restart requires policy.", node: node, path: "\(path).policy")
        }
        return HostwrightRestart(policy: try enumString(policy, path: "\(path).policy"))
    }

    private func decodeUpdate(_ node: Node, path: String) throws -> HostwrightUpdatePolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["strategy", "maxSurge", "maxUnavailable", "progressDeadline"]
        )
        let strategyRaw = try values["strategy"].map {
            try string($0, path: "\(path).strategy")
        } ?? HostwrightUpdateStrategy.rolling.rawValue
        guard let strategy = HostwrightUpdateStrategy(rawValue: strategyRaw) else {
            throw ManifestParser.failure(
                "update.strategy must be rolling or recreate.",
                code: .manifestValidationFailed,
                node: values["strategy"],
                path: "\(path).strategy"
            )
        }
        return HostwrightUpdatePolicy(
            strategy: strategy,
            maxSurge: try values["maxSurge"].map { try integer($0, path: "\(path).maxSurge") } ?? 1,
            maxUnavailable: try values["maxUnavailable"].map {
                try integer($0, path: "\(path).maxUnavailable")
            } ?? 0,
            progressDeadline: try duration(
                values["progressDeadline"],
                default: 300,
                path: "\(path).progressDeadline"
            )
        )
    }

    private func decodeHooks(_ node: Node, path: String) throws -> HostwrightHooks {
        let values = try mapping(node, path: path, allowed: ["postStart", "preStop"])
        return HostwrightHooks(
            postStart: try values["postStart"].map { try hook($0, path: "\(path).postStart") },
            preStop: try values["preStop"].map { try hook($0, path: "\(path).preStop") }
        )
    }

    private func hook(_ node: Node, path: String) throws -> [String] {
        let values = try mapping(node, path: path, allowed: ["exec"])
        guard let exec = values["exec"] else {
            throw ManifestParser.failure("Hook requires exec.", node: node, path: "\(path).exec")
        }
        return try strings(exec, path: "\(path).exec")
    }

    private func secrets(_ node: Node, path: String) throws -> [String: HostwrightSecretReference] {
        var result: [String: HostwrightSecretReference] = [:]
        for (key, value) in try stringMap(node, path: path) {
            do {
                result[key] = try HostwrightSecretReference.parse(value)
            } catch {
                throw ManifestParser.failure(
                    "Secret environment reference for '\(key)' must use one of: keychain://<service>/<account>, env-file:///absolute/path#KEY, local-file:///absolute/path, external://<provider>/<item>, or plugin://<provider>/<item>.",
                    code: .manifestValidationFailed,
                    node: node,
                    path: "\(path).\(key)"
                )
            }
        }
        return result
    }

    private func stringMap(_ node: Node, path: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for pair in try rawMapping(node, path: path) {
            let key = try keyString(pair.key, path: path)
            result[key] = try string(pair.value, path: "\(path).\(key)")
        }
        return result
    }

    private func strings(_ node: Node, path: String) throws -> [String] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }
        return try sequence.enumerated().map { index, child in
            try string(child, path: "\(path)[\(index)]")
        }
    }

    private func decodeMounts(
        _ node: Node,
        path: String
    ) throws -> (legacyVolumes: [String], mounts: [HostwrightMountSpec]) {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }

        var legacyVolumes: [String] = []
        var mounts: [HostwrightMountSpec] = []
        legacyVolumes.reserveCapacity(sequence.count)
        mounts.reserveCapacity(sequence.count)

        for (index, child) in sequence.enumerated() {
            let itemPath = "\(path)[\(index)]"
            if case .scalar = child {
                let value = try string(child, path: itemPath)
                legacyVolumes.append(value)
                if let mount = HostwrightMountSpec.legacy(value) {
                    mounts.append(mount)
                }
                continue
            }

            let mount = try decodeMount(child, path: itemPath)
            mounts.append(mount)
        }

        return (legacyVolumes, mounts)
    }

    private func decodeMount(_ node: Node, path: String) throws -> HostwrightMountSpec {
        let values = try mapping(
            node,
            path: path,
            allowed: ["type", "source", "target", "readOnly", "mode", "size"]
        )
        let kindRaw = try requiredString(values["type"], path: "\(path).type", message: "Mount type is required.")
        guard let kind = HostwrightMountKind(rawValue: kindRaw) else {
            throw ManifestParser.failure(
                "Mount type must be bind, volume, or tmpfs.",
                code: .manifestValidationFailed,
                node: values["type"],
                path: "\(path).type"
            )
        }

        let source = try values["source"].map { try string($0, path: "\(path).source") }
        let target = try requiredString(values["target"], path: "\(path).target", message: "Mount target is required.")
        let readOnly = try values["readOnly"].map { try boolean($0, path: "\(path).readOnly") } ?? false
        let mode = try values["mode"].map { try string($0, path: "\(path).mode") }
        let size = try values["size"].map { try string($0, path: "\(path).size") }

        switch kind {
        case .bind, .volume:
            guard source != nil else {
                throw ManifestParser.failure(
                    "Mount source is required for \(kind.rawValue) mounts.",
                    code: .manifestValidationFailed,
                    path: "\(path).source"
                )
            }
            if values["mode"] != nil || values["size"] != nil {
                throw ManifestParser.failure(
                    "\(kind.rawValue) mounts accept only type, source, target, and readOnly.",
                    code: .manifestValidationFailed,
                    node: node,
                    path: path
                )
            }
        case .tmpfs:
            if values["source"] != nil {
                throw ManifestParser.failure(
                    "tmpfs mounts must not declare source.",
                    code: .manifestValidationFailed,
                    node: values["source"],
                    path: "\(path).source"
                )
            }
        }

        return HostwrightMountSpec(
            kind: kind,
            source: source,
            target: target,
            readOnly: readOnly,
            mode: mode,
            size: size
        )
    }

    private func mapping(_ node: Node, path: String, allowed: Set<String>) throws -> [String: Node] {
        var result: [String: Node] = [:]
        for pair in try rawMapping(node, path: path) {
            let key = try keyString(pair.key, path: path)
            guard allowed.contains(key) else {
                let context: String
                if path == "$" {
                    context = "top-level manifest"
                } else if path.contains(".volumes.") {
                    context = "top-level volume"
                } else if path.contains(".networks."), !path.contains(".services.") {
                    context = "top-level network"
                } else if path.hasSuffix(".health") {
                    context = "health"
                } else if path.hasSuffix(".restart") {
                    context = "restart"
                } else if path.contains(".services.") {
                    context = "service"
                } else {
                    context = "manifest"
                }
                let networkingFields = Set([
                    "dns", "dns_search", "domainname", "hostname", "extra_hosts",
                    "aliases", "expose", "network_mode", "networks"
                ])
                let networkingHint = networkingFields.contains(key)
                    ? " DNS, service discovery, network aliases, and broad exposure settings are unsupported in this release."
                    : ""
                throw ManifestParser.failure(
                    "Unsupported \(context) field '\(key)'.\(networkingHint)",
                    code: .manifestUnsupportedFeature,
                    node: pair.key,
                    path: "\(path).\(key)"
                )
            }
            result[key] = pair.value
        }
        return result
    }

    private func rawMapping(_ node: Node, path: String) throws -> Node.Mapping {
        guard case .mapping(let mapping) = node else {
            throw ManifestParser.failure("Expected a mapping.", node: node, path: path)
        }
        return mapping
    }

    private func keyString(_ node: Node, path: String) throws -> String {
        guard case .scalar(let scalar) = node, node.tag.rawValue == Tag.Name.str.rawValue else {
            throw ManifestParser.failure(
                "Mapping keys must be unambiguous strings.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return scalar.string
    }

    private func string(_ node: Node, path: String) throws -> String {
        guard case .scalar(let scalar) = node, node.tag.rawValue == Tag.Name.str.rawValue else {
            throw ManifestParser.failure(
                "Expected an unambiguous string; quote values that YAML would coerce.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return scalar.string
    }

    private func enumString(_ node: Node, path: String) throws -> String {
        guard case .scalar(let scalar) = node else {
            throw ManifestParser.failure("Expected a scalar value.", node: node, path: path)
        }
        return scalar.string
    }

    private func integer(_ node: Node, path: String) throws -> Int {
        guard case .scalar(let scalar) = node,
              node.tag.rawValue == Tag.Name.int.rawValue,
              scalar.string.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              let value = Int(scalar.string)
        else {
            throw ManifestParser.failure(
                "Expected a canonical non-negative decimal integer.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return value
    }

    private func versionInteger(_ node: Node) throws -> Int {
        do {
            return try integer(node, path: "$.version")
        } catch {
            throw ManifestParser.failure(
                "Manifest version must be an integer. Supported manifest version is \(HostwrightManifest.currentVersion).",
                code: .manifestValidationFailed,
                node: node,
                path: "$.version"
            )
        }
    }

    private func requiredInteger(
        _ node: Node?,
        path: String,
        message: String
    ) throws -> Int {
        guard let node else {
            throw ManifestParser.failure(
                message,
                code: .manifestValidationFailed,
                path: path
            )
        }
        return try integer(node, path: path)
    }

    private func requiredString(
        _ node: Node?,
        path: String,
        message: String
    ) throws -> String {
        guard let node else {
            throw ManifestParser.failure(
                message,
                code: .manifestValidationFailed,
                path: path
            )
        }
        return try string(node, path: path)
    }

    private func requiredAuthorityType(
        _ node: Node?,
        path: String
    ) throws -> HostwrightImageTrustAuthorityType {
        let raw = try requiredString(
            node,
            path: path,
            message: "imageTrust authority type is required."
        )
        guard let type = HostwrightImageTrustAuthorityType(rawValue: raw) else {
            throw ManifestParser.failure(
                "imageTrust authority type must be one of: keyed, keyless.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return type
    }

    private func requiredImageSBOMRequirement(
        _ node: Node?,
        path: String
    ) throws -> HostwrightImageSBOMRequirement {
        let raw = try requiredString(
            node,
            path: path,
            message: "imageSBOM.requirement is required."
        )
        guard let requirement = HostwrightImageSBOMRequirement(rawValue: raw) else {
            throw ManifestParser.failure(
                "imageSBOM.requirement must be one of: optional, required.",
                code: .manifestValidationFailed,
                path: path
            )
        }
        return requirement
    }

    private func requiredImageProvenanceRequirement(
        _ node: Node?,
        path: String
    ) throws -> HostwrightImageProvenanceRequirement {
        let raw = try requiredString(
            node,
            path: path,
            message: "imageProvenance.requirement is required."
        )
        guard let requirement = HostwrightImageProvenanceRequirement(rawValue: raw) else {
            throw ManifestParser.failure(
                "imageProvenance.requirement must be one of: optional, required.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return requirement
    }

    private func requiredImageVulnerabilityEnum<Value>(
        _ node: Node?,
        path: String,
        message: String,
        allowed _: Value.Type,
        allowedValues: String
    ) throws -> Value where Value: RawRepresentable, Value.RawValue == String {
        let raw = try requiredString(node, path: path, message: message)
        guard let value = Value(rawValue: raw) else {
            throw ManifestParser.failure(
                "\(path.dropFirst(2)) must be one of: \(allowedValues).",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return value
    }

    private func unsignedID(_ node: Node, path: String) throws -> UInt32 {
        let value = try integer(node, path: path)
        guard let identifier = UInt32(exactly: value) else {
            throw ManifestParser.failure(
                "Numeric ID must fit an unsigned 32-bit integer.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return identifier
    }

    private func boolean(_ node: Node, path: String) throws -> Bool {
        guard case .scalar(let scalar) = node,
              node.tag.rawValue == Tag.Name.bool.rawValue
        else {
            throw ManifestParser.failure(
                "Expected true or false.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        switch scalar.string {
        case "true": return true
        case "false": return false
        default:
            throw ManifestParser.failure(
                "Boolean values must use lowercase true or false.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
    }

    private func requiredBoolean(
        _ node: Node?,
        path: String,
        message: String
    ) throws -> Bool {
        guard let node else {
            throw ManifestParser.failure(
                message,
                code: .manifestValidationFailed,
                path: path
            )
        }
        return try boolean(node, path: path)
    }

    private func requiredStrings(
        _ node: Node?,
        path: String,
        message: String
    ) throws -> [String] {
        guard let node else {
            throw ManifestParser.failure(
                message,
                code: .manifestValidationFailed,
                path: path
            )
        }
        return try strings(node, path: path)
    }

    private func duration(_ node: Node?, default defaultValue: Int, path: String) throws -> Int {
        guard let node else { return defaultValue }
        return try seconds(string(node, path: path), node: node, path: path)
    }

    private func seconds(_ value: String, node: Node?, path: String) throws -> Int {
        guard value.hasSuffix("s"),
              let seconds = Int(value.dropLast()),
              seconds >= 0,
              String(seconds) == value.dropLast()
        else {
            throw ManifestParser.failure(
                "Duration must be a canonical seconds value such as 10s.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return seconds
    }
}
