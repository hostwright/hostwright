import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightSecrets
import Yams

public enum ManifestParser {
    public static let maximumUTF8Bytes = 1_048_576
    public static let maximumDepth = 64
    public static let maximumExpandedNodes = 100_000
    public static let limitation = "Hostwright Manifest v3 accepts one bounded YAML document."

    public static func parse(_ text: String) throws -> HostwrightManifest {
        (try parse(text, cancellationCheck: { false }, allowLegacyFlatResources: false)).manifest
    }

    public static func parse(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> HostwrightManifest {
        (try parse(
            text,
            cancellationCheck: cancellationCheck,
            allowLegacyFlatResources: false
        )).manifest
    }

    static func parseForMigrationPreview(_ text: String) throws -> ManifestMigrationParseResult {
        try parse(
            text,
            cancellationCheck: { false },
            allowLegacyFlatResources: true
        )
    }

    private static func parse(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool,
        allowLegacyFlatResources: Bool
    ) throws -> ManifestMigrationParseResult {
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
            let decoder = ManifestNodeDecoder(
                allowLegacyFlatResources: allowLegacyFlatResources
            )
            return ManifestMigrationParseResult(
                manifest: try decoder.decode(root),
                usedLegacyFlatResources: decoder.usedLegacyFlatResources,
                legacyFlatResourcePaths: decoder.legacyFlatResourcePaths
            )
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

struct ManifestMigrationParseResult {
    let manifest: HostwrightManifest
    let usedLegacyFlatResources: Bool
    let legacyFlatResourcePaths: [String]
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

private final class ManifestNodeDecoder {
    let allowLegacyFlatResources: Bool
    private(set) var usedLegacyFlatResources = false
    private(set) var legacyFlatResourcePaths: [String] = []

    init(allowLegacyFlatResources: Bool = false) {
        self.allowLegacyFlatResources = allowLegacyFlatResources
    }

    func decode(_ root: Node) throws -> HostwrightManifest {
        let values = try mapping(
            root,
            path: "$",
            allowed: [
                "version", "project", "imagePolicy", "imageTrust", "imageSBOM",
                "imageVulnerability", "imageProvenance", "volumes", "networks",
                "certificates", "ingress", "tunnels", "restartBudget", "maintenance", "retention",
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
        let restartBudget = try values["restartBudget"].map {
            try decodeProjectRestartBudget($0, path: "$.restartBudget")
        }
        let maintenance = try values["maintenance"].map {
            try decodeMaintenance($0, path: "$.maintenance")
        }
        let retention = try values["retention"].map {
            try decodeRetention($0, path: "$.retention")
        }
        let volumes = try values["volumes"].map {
            try decodeVolumeDeclarations($0, path: "$.volumes")
        } ?? [:]
        let networks = try values["networks"].map {
            try decodeNetworkDefinitions($0, path: "$.networks")
        } ?? [:]
        let certificates = try values["certificates"].map {
            try decodeCertificateDeclarations($0, path: "$.certificates")
        } ?? [:]
        let ingress = try values["ingress"].map {
            try decodeIngressListeners($0, path: "$.ingress")
        } ?? [:]
        let tunnels = try values["tunnels"].map {
            try decodeTunnelDeclarations($0, path: "$.tunnels")
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
            restartBudget: restartBudget,
            maintenance: maintenance,
            retention: retention,
            volumes: volumes,
            networks: networks,
            certificates: certificates,
            ingress: ingress,
            tunnels: tunnels,
            services: services
        )
    }

    private func decodeTunnelDeclarations(
        _ node: Node,
        path: String
    ) throws -> [String: HostwrightTunnelDeclaration] {
        let entries = try rawMapping(node, path: path)
        guard entries.count <= HostwrightTunnelDeclaration.maximumDeclarations else {
            throw ManifestParser.failure(
                "Tunnels accepts at most \(HostwrightTunnelDeclaration.maximumDeclarations) declarations.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        var result: [String: HostwrightTunnelDeclaration] = [:]
        for pair in entries {
            let name = try keyString(pair.key, path: path)
            let declarationPath = "\(path).\(name)"
            let values = try mapping(
                pair.value,
                path: declarationPath,
                allowed: [
                    "targetService", "targetPort", "peerUUID",
                    "role", "trust", "bindEndpoint", "authenticatedEndpoints",
                    "relayEndpoint", "bonjourDiscovery"
                ]
            )
            let targetService = try requiredString(
                values["targetService"],
                path: "\(declarationPath).targetService",
                message: "Tunnel targetService is required."
            )
            let targetPort = try requiredInteger(
                values["targetPort"],
                path: "\(declarationPath).targetPort",
                message: "Tunnel targetPort is required."
            )
            let peerUUID = try requiredString(
                values["peerUUID"],
                path: "\(declarationPath).peerUUID",
                message: "Tunnel peerUUID is required."
            )
            guard HostwrightResourceUUID.isValid(peerUUID),
                  peerUUID == peerUUID.lowercased() else {
                throw ManifestParser.failure(
                    "Tunnel peerUUID must be a canonical lowercase Hostwright UUID.",
                    code: .manifestValidationFailed,
                    node: values["peerUUID"],
                    path: "\(declarationPath).peerUUID"
                )
            }
            let roleRaw = try values["role"].map {
                try string($0, path: "\(declarationPath).role")
            } ?? HostwrightTunnelRole.localLoopback.rawValue
            guard let role = HostwrightTunnelRole(rawValue: roleRaw) else {
                throw ManifestParser.failure(
                    "Tunnel role must be one of: local-loopback, listener, dialer.",
                    code: .manifestValidationFailed,
                    node: values["role"],
                    path: "\(declarationPath).role"
                )
            }
            let trust = try values["trust"].map {
                try decodeTunnelTrust($0, path: "\(declarationPath).trust")
            }
            let bindEndpoint = try values["bindEndpoint"].map {
                try decodeTunnelBindEndpoint($0, path: "\(declarationPath).bindEndpoint")
            }
            let endpoints = try values["authenticatedEndpoints"].map {
                try decodeTunnelEndpoints(
                    $0,
                    path: "\(declarationPath).authenticatedEndpoints"
                )
            } ?? []
            let relayEndpoint = try values["relayEndpoint"].map {
                try decodeTunnelEndpoint($0, path: "\(declarationPath).relayEndpoint")
            }
            let bonjourDiscovery = try values["bonjourDiscovery"].map {
                try boolean($0, path: "\(declarationPath).bonjourDiscovery")
            } ?? true
            result[name] = HostwrightTunnelDeclaration(
                targetService: targetService,
                targetPort: targetPort,
                peerUUID: peerUUID,
                role: role,
                trust: trust,
                bindEndpoint: bindEndpoint,
                authenticatedEndpoints: endpoints,
                relayEndpoint: relayEndpoint,
                bonjourDiscovery: bonjourDiscovery
            )
        }
        return result
    }

    private func decodeTunnelTrust(
        _ node: Node,
        path: String
    ) throws -> HostwrightTunnelTrust {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "wireRouteUUID", "wireGeneration",
                "localIdentitySHA256", "peerTrustAnchorSHA256",
                "peerCertificateSHA256", "peerDNSName", "peerIdentityURI"
            ]
        )
        return HostwrightTunnelTrust(
            wireRouteUUID: try requiredString(
                values["wireRouteUUID"],
                path: "\(path).wireRouteUUID",
                message: "Tunnel trust wireRouteUUID is required."
            ),
            wireGeneration: Int64(try requiredInteger(
                values["wireGeneration"],
                path: "\(path).wireGeneration",
                message: "Tunnel trust wireGeneration is required."
            )),
            localIdentitySHA256: try requiredString(
                values["localIdentitySHA256"],
                path: "\(path).localIdentitySHA256",
                message: "Tunnel trust localIdentitySHA256 is required."
            ),
            peerTrustAnchorSHA256: try requiredString(
                values["peerTrustAnchorSHA256"],
                path: "\(path).peerTrustAnchorSHA256",
                message: "Tunnel trust peerTrustAnchorSHA256 is required."
            ),
            peerCertificateSHA256: try requiredString(
                values["peerCertificateSHA256"],
                path: "\(path).peerCertificateSHA256",
                message: "Tunnel trust peerCertificateSHA256 is required."
            ),
            peerDNSName: try values["peerDNSName"].map {
                try string($0, path: "\(path).peerDNSName")
            },
            peerIdentityURI: try values["peerIdentityURI"].map {
                try string($0, path: "\(path).peerIdentityURI")
            }
        )
    }

    private func decodeTunnelBindEndpoint(
        _ node: Node,
        path: String
    ) throws -> HostwrightTunnelBindEndpoint {
        let values = try mapping(node, path: path, allowed: ["host", "port"])
        let host = try requiredString(
            values["host"],
            path: "\(path).host",
            message: "Tunnel bindEndpoint host is required."
        )
        guard HostwrightTunnelManifestEndpoint.canonicalHost(host) == host else {
            throw ManifestParser.failure(
                "Tunnel bindEndpoint host must be a canonical hostname, IPv4 address, or IPv6 address.",
                code: .manifestValidationFailed,
                node: values["host"],
                path: "\(path).host"
            )
        }
        return HostwrightTunnelBindEndpoint(
            host: host,
            port: try requiredInteger(
                values["port"],
                path: "\(path).port",
                message: "Tunnel bindEndpoint port is required."
            )
        )
    }

    private func decodeTunnelEndpoints(
        _ node: Node,
        path: String
    ) throws -> [HostwrightTunnelManifestEndpoint] {
        guard case .sequence(let sequence) = node,
              sequence.count <= HostwrightTunnelDeclaration.maximumAuthenticatedEndpoints else {
            throw ManifestParser.failure(
                "Tunnel authenticatedEndpoints must be a sequence of at most \(HostwrightTunnelDeclaration.maximumAuthenticatedEndpoints) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map {
            try decodeTunnelEndpoint($0.element, path: "\(path)[\($0.offset)]")
        }
    }

    private func decodeTunnelEndpoint(
        _ node: Node,
        path: String
    ) throws -> HostwrightTunnelManifestEndpoint {
        let values = try mapping(node, path: path, allowed: ["scheme", "host", "port"])
        let schemeRaw = try values["scheme"].map { try string($0, path: "\(path).scheme") }
            ?? HostwrightTunnelEndpointScheme.tls.rawValue
        guard let scheme = HostwrightTunnelEndpointScheme(rawValue: schemeRaw) else {
            throw ManifestParser.failure(
                "Tunnel endpoint scheme must be tls.",
                code: .manifestValidationFailed,
                node: values["scheme"],
                path: "\(path).scheme"
            )
        }
        let host = try requiredString(values["host"], path: "\(path).host", message: "Tunnel endpoint host is required.")
        guard HostwrightTunnelManifestEndpoint.canonicalHost(host) == host else {
            throw ManifestParser.failure(
                "Tunnel endpoint host must be a canonical hostname, IPv4 address, or IPv6 address.",
                code: .manifestValidationFailed,
                node: values["host"],
                path: "\(path).host"
            )
        }
        return HostwrightTunnelManifestEndpoint(
            scheme: scheme,
            host: host,
            port: try requiredInteger(values["port"], path: "\(path).port", message: "Tunnel endpoint port is required.")
        )
    }

    private func decodeCertificateDeclarations(
        _ node: Node,
        path: String
    ) throws -> [String: HostwrightCertificateDeclaration] {
        let entries = try rawMapping(node, path: path)
        guard entries.count <= HostwrightCertificateDeclaration.maximumCertificates else {
            throw ManifestParser.failure("Certificates accepts at most \(HostwrightCertificateDeclaration.maximumCertificates) declarations.", code: .manifestValidationFailed, node: node, path: path)
        }
        var result: [String: HostwrightCertificateDeclaration] = [:]
        for pair in entries {
            let name = try keyString(pair.key, path: path)
            let declarationPath = "\(path).\(name)"
            let values = try mapping(pair.value, path: declarationPath, allowed: ["source", "identitySHA256", "issuer", "renewBeforeSeconds", "validitySeconds", "statusPolicy"])
            let sourceRaw = try requiredString(values["source"], path: "\(declarationPath).source", message: "Certificate source is required.")
            guard let source = HostwrightCertificateSourceKind(rawValue: sourceRaw) else {
                throw ManifestParser.failure("Certificate source must be one of: imported, localCA, provider.", code: .manifestValidationFailed, node: values["source"], path: "\(declarationPath).source")
            }
            let identitySHA256 = try values["identitySHA256"].map { try string($0, path: "\(declarationPath).identitySHA256") }
            let issuer = try values["issuer"].map { try string($0, path: "\(declarationPath).issuer") }
            let renewBeforeSeconds = try values["renewBeforeSeconds"].map { try integer($0, path: "\(declarationPath).renewBeforeSeconds") } ?? HostwrightCertificateDeclaration.defaultRenewBeforeSeconds
            let validitySeconds = try values["validitySeconds"].map { try integer($0, path: "\(declarationPath).validitySeconds") } ?? HostwrightCertificateDeclaration.defaultValiditySeconds
            let statusRaw = try values["statusPolicy"].map { try string($0, path: "\(declarationPath).statusPolicy") } ?? HostwrightCertificateStatusPolicy.ifAvailable.rawValue
            guard let statusPolicy = HostwrightCertificateStatusPolicy(rawValue: statusRaw) else {
                throw ManifestParser.failure("Certificate statusPolicy must be one of: disabled, ifAvailable, required.", code: .manifestValidationFailed, node: values["statusPolicy"], path: "\(declarationPath).statusPolicy")
            }
            switch source {
            case .imported:
                guard identitySHA256?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                    throw ManifestParser.failure("Imported certificate requires a lowercase 64-hex identitySHA256.", code: .manifestValidationFailed, node: values["identitySHA256"], path: "\(declarationPath).identitySHA256")
                }
                guard issuer == nil else { throw ManifestParser.failure("Imported certificate must not declare issuer.", code: .manifestValidationFailed, node: values["issuer"], path: "\(declarationPath).issuer") }
            case .localCA:
                guard identitySHA256 == nil, issuer == nil else { throw ManifestParser.failure("localCA certificate must not declare identitySHA256 or issuer.", code: .manifestValidationFailed, node: pair.value, path: declarationPath) }
            case .provider:
                guard identitySHA256 == nil else { throw ManifestParser.failure("Provider certificate must not declare identitySHA256.", code: .manifestValidationFailed, node: values["identitySHA256"], path: "\(declarationPath).identitySHA256") }
                guard let issuer, HostwrightNetworkIdentity.isValidManifestName(issuer) else { throw ManifestParser.failure("Provider certificate requires a valid exact issuer ID.", code: .manifestValidationFailed, node: values["issuer"], path: "\(declarationPath).issuer") }
            }
            result[name] = HostwrightCertificateDeclaration(source: source, identitySHA256: identitySHA256, issuer: issuer, renewBeforeSeconds: renewBeforeSeconds, validitySeconds: validitySeconds, statusPolicy: statusPolicy)
        }
        return result
    }

    private func decodeIngressListeners(
        _ node: Node,
        path: String
    ) throws -> [String: HostwrightIngressListener] {
        let entries = try rawMapping(node, path: path)
        guard entries.count <= HostwrightIngressListener.maximumListeners else {
            throw ManifestParser.failure(
                "Ingress accepts at most \(HostwrightIngressListener.maximumListeners) listeners.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        var result: [String: HostwrightIngressListener] = [:]
        for pair in entries {
            let name = try keyString(pair.key, path: path)
            let listenerPath = "\(path).\(name)"
            let values = try mapping(
                pair.value,
                path: listenerPath,
                allowed: ["bind", "certificate", "exposure", "peers", "port", "routes"]
            )
            let bindAddress = try values["bind"].map {
                try string($0, path: "\(listenerPath).bind")
            } ?? NetworkBindAddressPolicy.localhostBindAddress
            let port = try requiredInteger(
                values["port"],
                path: "\(listenerPath).port",
                message: "Ingress listener port is required."
            )
            let exposure = try values["exposure"].map {
                try decodePortExposure(
                    $0,
                    path: "\(listenerPath).exposure"
                )
            } ?? .localhost
            let certificate = try values["certificate"].map {
                try string($0, path: "\(listenerPath).certificate")
            }
            let peers = try values["peers"].map {
                try decodeIngressPeers($0, path: "\(listenerPath).peers")
            } ?? []
            guard let routesNode = values["routes"] else {
                throw ManifestParser.failure(
                    "Ingress listener routes are required.",
                    code: .manifestValidationFailed,
                    node: pair.value,
                    path: "\(listenerPath).routes"
                )
            }
            let routes = try decodeIngressRoutes(
                routesNode,
                path: "\(listenerPath).routes"
            )
            result[name] = HostwrightIngressListener(
                bindAddress: bindAddress,
                port: port,
                exposure: exposure,
                certificate: certificate,
                peers: peers,
                routes: routes
            )
        }
        return result
    }

    private func decodeIngressPeers(_ node: Node, path: String) throws -> [HostwrightIngressPeerSelector] {
        guard case .sequence(let sequence) = node,
              sequence.count <= HostwrightIngressListener.maximumPeers else {
            throw ManifestParser.failure("Ingress peers must be a sequence of at most \(HostwrightIngressListener.maximumPeers) entries.", code: .manifestValidationFailed, node: node, path: path)
        }
        return try sequence.enumerated().map { index, entry in
            let entryPath = "\(path)[\(index)]"
            let values = try mapping(entry, path: entryPath, allowed: ["service", "role"])
            let service = try requiredString(values["service"], path: "\(entryPath).service", message: "Ingress peer service is required.")
            let roleRaw = try requiredString(values["role"], path: "\(entryPath).role", message: "Ingress peer role is required.")
            guard let role = HostwrightIdentityRole(rawValue: roleRaw) else {
                throw ManifestParser.failure("Ingress peer role must be one of: workload, ingress, tunnel, node.", code: .manifestValidationFailed, node: values["role"], path: "\(entryPath).role")
            }
            return HostwrightIngressPeerSelector(service: service, role: role)
        }
    }

    private func decodeIngressRoutes(
        _ node: Node,
        path: String
    ) throws -> [HostwrightIngressRoute] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure(
                "Ingress routes must be a sequence.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        guard sequence.count <= HostwrightIngressListener.maximumRoutes else {
            throw ManifestParser.failure(
                "Ingress accepts at most \(HostwrightIngressListener.maximumRoutes) routes per listener.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let routePath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: routePath,
                allowed: [
                    "hostname", "methods", "pathPrefix", "protocol",
                    "targetPort", "targetService"
                ]
            )
            let hostname = try requiredString(
                values["hostname"],
                path: "\(routePath).hostname",
                message: "Ingress route hostname is required."
            )
            let pathPrefix = try values["pathPrefix"].map {
                try string($0, path: "\(routePath).pathPrefix")
            } ?? "/"
            let methods = try values["methods"].map {
                try strings($0, path: "\(routePath).methods")
            } ?? ["GET"]
            let protocolRaw = try values["protocol"].map {
                try string($0, path: "\(routePath).protocol")
            } ?? HostwrightIngressRouteProtocol.http.rawValue
            guard let protocolName = HostwrightIngressRouteProtocol(
                rawValue: protocolRaw
            ) else {
                throw ManifestParser.failure(
                    "Ingress route protocol must be one of: http, websocket.",
                    code: .manifestValidationFailed,
                    node: values["protocol"],
                    path: "\(routePath).protocol"
                )
            }
            let targetService = try requiredString(
                values["targetService"],
                path: "\(routePath).targetService",
                message: "Ingress route targetService is required."
            )
            let targetPort = try requiredInteger(
                values["targetPort"],
                path: "\(routePath).targetPort",
                message: "Ingress route targetPort is required."
            )
            return HostwrightIngressRoute(
                hostname: hostname,
                pathPrefix: pathPrefix,
                methods: methods,
                protocolName: protocolName,
                targetService: targetService,
                targetPort: targetPort
            )
        }.sorted(by: HostwrightIngressRoute.canonicalPrecedes)
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
                "ports", "hostAccess", "networks", "networkPolicy", "volumes", "health", "probes", "restart", "update", "hooks", "scheduling",
                "rosetta", "virtualization", "readOnlyRootFilesystem", "shmSize"
            ]
        )

        let image = try values["image"].map { try string($0, path: "\(path).image") }
        let replicas = try values["replicas"].map { try integer($0, path: "\(path).replicas") } ?? 1
        let platform = try values["platform"].map { try decodePlatform($0, path: "\(path).platform") } ?? HostwrightPlatform()
        let resources = try values["resources"].map {
            try decodeResources(
                $0,
                path: "\(path).resources",
                allowLegacyFlatResources: allowLegacyFlatResources
            )
        }
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
        let publishedEndpoints = try values["ports"].map {
            try decodePublishedEndpoints($0, path: "\(path).ports")
        } ?? (ports: [], sockets: [])
        let publishedPorts = publishedEndpoints.ports
        let publishedSockets = publishedEndpoints.sockets
        let hostAccess = try values["hostAccess"].map {
            try decodeHostAccess($0, path: "\(path).hostAccess")
        } ?? []
        let ports = publishedPorts.compactMap(\.canonicalLegacyLiteral)
        let networks = try values["networks"].map {
            try decodeServiceNetworks($0, path: "\(path).networks")
        } ?? []
        let networkPolicy = try values["networkPolicy"].map {
            try decodeNetworkPolicy($0, path: "\(path).networkPolicy")
        }
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
        let scheduling = try values["scheduling"].map {
            try decodeScheduling($0, path: "\(path).scheduling")
        }
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
            scheduling: scheduling,
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
            publishedSockets: publishedSockets,
            hostAccess: hostAccess,
            networks: networks,
            networkPolicy: networkPolicy,
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

    private func decodeNetworkPolicy(
        _ node: Node,
        path: String
    ) throws -> HostwrightServiceNetworkPolicy {
        let values = try mapping(node, path: path, allowed: ["ingress", "egress"])
        let ingress = try values["ingress"].map {
            try decodeNetworkPolicyRules($0, path: "\(path).ingress")
        } ?? []
        let egress = try values["egress"].map {
            try decodeNetworkPolicyRules($0, path: "\(path).egress")
        } ?? []
        return HostwrightServiceNetworkPolicy(ingress: ingress, egress: egress)
    }

    private func decodeNetworkPolicyRules(
        _ node: Node,
        path: String
    ) throws -> [HostwrightNetworkPolicyRule] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }

        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: itemPath,
                allowed: ["project", "service", "identity", "protocol", "address", "port", "dns"]
            )
            let protocolName = try values["protocol"].map { value -> HostwrightNetworkPolicyProtocol in
                let raw = try string(value, path: "\(itemPath).protocol")
                guard let protocolName = HostwrightNetworkPolicyProtocol(rawValue: raw) else {
                    throw ManifestParser.failure(
                        "Network policy protocol must be one of: tcp, udp.",
                        code: .manifestValidationFailed,
                        node: value,
                        path: "\(itemPath).protocol"
                    )
                }
                return protocolName
            }
            return HostwrightNetworkPolicyRule(
                project: try values["project"].map { try string($0, path: "\(itemPath).project") },
                service: try values["service"].map { try string($0, path: "\(itemPath).service") },
                identity: try values["identity"].map { try string($0, path: "\(itemPath).identity") },
                protocolName: protocolName,
                address: try values["address"].map { try string($0, path: "\(itemPath).address") },
                port: try values["port"].map { try integer($0, path: "\(itemPath).port") },
                dns: try values["dns"].map { try string($0, path: "\(itemPath).dns") }
            )
        }
        .sorted { $0.canonicalKey < $1.canonicalKey }
    }

    private func decodeHostAccess(
        _ node: Node,
        path: String
    ) throws -> [HostwrightHostAccessEndpoint] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure(
                "Expected a sequence.",
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: itemPath,
                allowed: [
                    "hostname", "protocol", "addressClass", "port"
                ]
            )
            let hostname = try requiredString(
                values["hostname"],
                path: "\(itemPath).hostname",
                message: "Host access endpoint hostname is required."
            )
            let rawProtocol = try requiredString(
                values["protocol"],
                path: "\(itemPath).protocol",
                message: "Host access endpoint protocol is required."
            )
            guard let protocolName = HostwrightHostAccessProtocol(
                rawValue: rawProtocol
            ) else {
                throw ManifestParser.failure(
                    "Host access protocol must be one of: tcp, udp.",
                    code: .manifestValidationFailed,
                    node: values["protocol"],
                    path: "\(itemPath).protocol"
                )
            }
            let rawAddressClass = try requiredString(
                values["addressClass"],
                path: "\(itemPath).addressClass",
                message: "Host access endpoint addressClass is required."
            )
            guard let addressClass =
                    HostwrightHostAccessAddressClass(
                        rawValue: rawAddressClass
                    ) else {
                throw ManifestParser.failure(
                    "Host access addressClass must be one of: loopback, interface.",
                    code: .manifestValidationFailed,
                    node: values["addressClass"],
                    path: "\(itemPath).addressClass"
                )
            }
            let port = try values["port"].map {
                try integer($0, path: "\(itemPath).port")
            }
            guard let port else {
                throw ManifestParser.failure(
                    "Host access endpoint port is required.",
                    code: .manifestValidationFailed,
                    node: child,
                    path: "\(itemPath).port"
                )
            }
            return HostwrightHostAccessEndpoint(
                hostname: hostname,
                protocolName: protocolName,
                addressClass: addressClass,
                port: port
            )
        }.sorted(by: HostwrightHostAccessPolicy.canonicalPrecedes)
    }

    private func decodePublishedEndpoints(
        _ node: Node,
        path: String
    ) throws -> (
        ports: [HostwrightPublishedPort],
        sockets: [HostwrightPublishedSocket]
    ) {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Expected a sequence.", node: node, path: path)
        }

        var ports: [HostwrightPublishedPort] = []
        var sockets: [HostwrightPublishedSocket] = []
        for (index, child) in sequence.enumerated() {
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
                ports.append(publishedPort)

            case .mapping:
                let values = try mapping(
                    child,
                    path: itemPath,
                    allowed: ["bind", "exposure", "host", "mode", "protocol", "target"]
                )
                let rawProtocol = try values["protocol"].map {
                    try string($0, path: "\(itemPath).protocol")
                } ?? HostwrightPortProtocol.tcp.rawValue
                if rawProtocol == "unix" {
                    guard values["bind"] == nil else {
                        throw ManifestParser.failure(
                            "Unix socket publication does not accept bind.",
                            code: .manifestValidationFailed,
                            node: values["bind"],
                            path: "\(itemPath).bind"
                        )
                    }
                    guard values["exposure"] == nil else {
                        throw ManifestParser.failure(
                            "Unix socket publication does not accept exposure.",
                            code: .manifestValidationFailed,
                            node: values["exposure"],
                            path: "\(itemPath).exposure"
                        )
                    }
                    let target = try requiredString(
                        values["target"],
                        path: "\(itemPath).target",
                        message: "Unix socket publication requires an absolute container target."
                    )
                    let hostName = try values["host"].map {
                        try string($0, path: "\(itemPath).host")
                    }
                    let rawMode = try values["mode"].map {
                        try string($0, path: "\(itemPath).mode")
                    } ?? HostwrightPublishedSocketMode.ownerOnly.rawValue
                    guard let mode = HostwrightPublishedSocketMode(
                        rawValue: rawMode
                    ) else {
                        throw ManifestParser.failure(
                            "Unix socket mode must be one of: 0600, 0660.",
                            code: .manifestValidationFailed,
                            node: values["mode"],
                            path: "\(itemPath).mode"
                        )
                    }
                    sockets.append(
                        HostwrightPublishedSocket(
                            hostName: hostName,
                            containerPath: target,
                            mode: mode
                        )
                    )
                    continue
                }
                guard let protocolName = HostwrightPortProtocol(
                    rawValue: rawProtocol
                ) else {
                    throw ManifestParser.failure(
                        "protocol must be one of: tcp, udp, unix.",
                        code: .manifestValidationFailed,
                        node: values["protocol"],
                        path: "\(itemPath).protocol"
                    )
                }
                guard values["mode"] == nil else {
                    throw ManifestParser.failure(
                        "TCP and UDP port publication does not accept mode.",
                        code: .manifestValidationFailed,
                        node: values["mode"],
                        path: "\(itemPath).mode"
                    )
                }
                let target = try decodePortSpan(
                    values["target"],
                    path: "\(itemPath).target",
                    message: "Structured port mapping requires target."
                )
                let host = try values["host"].map { try decodePortSpanValue($0, path: "\(itemPath).host") }
                let bindAddress = try values["bind"].map { try string($0, path: "\(itemPath).bind") }
                let exposure = try values["exposure"].map { try decodePortExposure($0, path: "\(itemPath).exposure") }

                ports.append(
                    HostwrightPublishedPort(
                        host: host,
                        target: target,
                        protocolName: protocolName,
                        bindAddress: bindAddress ?? HostwrightPublishedPort.localhostBindAddress,
                        exposure: exposure
                    )
                )

            default:
                throw ManifestParser.failure(
                    "Port must use legacy \"host:container\" or a structured mapping.",
                    node: child,
                    path: itemPath
                )
            }
        }
        return (ports, sockets)
    }

    private func decodePortExposure(_ node: Node, path: String) throws -> HostwrightPortExposurePolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["allowedCIDRs", "authentication", "interfaces", "networkClasses", "scope"]
        )
        let scopeRaw = try requiredString(values["scope"], path: "\(path).scope", message: "Port exposure requires scope.")
        guard let scope = NetworkExposureScope(rawValue: scopeRaw), scope != .project else {
            throw ManifestParser.failure("Port exposure scope must be one of: localhost, lan, tunnel, public.", code: .manifestValidationFailed, node: values["scope"], path: "\(path).scope")
        }
        let authenticationRaw = try requiredString(values["authentication"], path: "\(path).authentication", message: "Port exposure requires authentication.")
        guard let authentication = NetworkExposureAuthentication(rawValue: authenticationRaw) else {
            throw ManifestParser.failure("Port exposure authentication must be one of: none, tls, mtls, authenticated-tunnel.", code: .manifestValidationFailed, node: values["authentication"], path: "\(path).authentication")
        }
        let interfaces = try values["interfaces"].map { try strings($0, path: "\(path).interfaces") } ?? []
        let classValues = try values["networkClasses"].map { try strings($0, path: "\(path).networkClasses") } ?? []
        let networkClasses = try classValues.enumerated().map { index, raw -> HostwrightNetworkClass in
            guard let value = HostwrightNetworkClass(rawValue: raw) else {
                throw ManifestParser.failure("Port exposure networkClasses must contain: private, vpn, public.", code: .manifestValidationFailed, node: values["networkClasses"], path: "\(path).networkClasses[\(index)]")
            }
            return value
        }
        let cidrs = try values["allowedCIDRs"].map { try strings($0, path: "\(path).allowedCIDRs") } ?? []
        for (index, cidr) in cidrs.enumerated() {
            guard NetworkExposurePolicyValidation.canonicalCIDR(cidr) == cidr else {
                throw ManifestParser.failure("Port exposure allowedCIDRs must contain canonical IPv4 or IPv6 CIDRs.", code: .manifestValidationFailed, node: values["allowedCIDRs"], path: "\(path).allowedCIDRs[\(index)]")
            }
        }
        guard Set(interfaces).count == interfaces.count,
              Set(networkClasses).count == networkClasses.count,
              Set(cidrs).count == cidrs.count else {
            throw ManifestParser.failure("Port exposure arrays must not contain duplicates.", code: .manifestValidationFailed, node: node, path: path)
        }
        guard interfaces.count <=
                HostwrightPortExposurePolicy.maximumInterfaceSelectors,
              cidrs.count <=
                HostwrightPortExposurePolicy.maximumAllowedCIDRs else {
            throw ManifestParser.failure(
                "Port exposure accepts at most 8 interfaces and 32 allowed CIDRs.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return HostwrightPortExposurePolicy(scope: scope, interfaces: interfaces, networkClasses: networkClasses, allowedCIDRs: cidrs, authentication: authentication)
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

    private func decodeResources(
        _ node: Node,
        path: String,
        allowLegacyFlatResources: Bool
    ) throws -> HostwrightResources {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "requests", "limits", "cpus", "memory"
            ]
        )
        let hasNested = values["requests"] != nil || values["limits"] != nil
        let hasLegacy = values["cpus"] != nil || values["memory"] != nil
        guard !(hasNested && hasLegacy) else {
            throw ManifestParser.failure(
                "resources cannot mix legacy flat cpus/memory with nested requests/limits.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        if hasLegacy {
            usedLegacyFlatResources = true
            legacyFlatResourcePaths.append(path)
            guard allowLegacyFlatResources else {
                throw ManifestParser.failure(
                    "Flat resources.cpus/resources.memory are legacy input. Run 'hostwright migrate preview' before execution.",
                    code: .manifestUnsupportedFeature,
                    node: node,
                    path: path
                )
            }
            let legacy = HostwrightResourceSet(
                cpus: try values["cpus"].map { try integer($0, path: "\(path).cpus") },
                memory: try values["memory"].map { try string($0, path: "\(path).memory") }
            )
            return HostwrightResources(requests: legacy, limits: legacy)
        }

        return HostwrightResources(
            requests: try values["requests"].map {
                try decodeResourceSet($0, path: "\(path).requests")
            } ?? HostwrightResourceSet(),
            limits: try values["limits"].map {
                try decodeResourceSet($0, path: "\(path).limits")
            }
        )
    }

    private func decodeResourceSet(_ node: Node, path: String) throws -> HostwrightResourceSet {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "cpus", "memory", "disk", "io", "network", "process"
            ]
        )
        return HostwrightResourceSet(
            cpus: try values["cpus"].map { try integer($0, path: "\(path).cpus") },
            memory: try values["memory"].map { try string($0, path: "\(path).memory") },
            disk: try values["disk"].map { try string($0, path: "\(path).disk") },
            io: try values["io"].map { try string($0, path: "\(path).io") },
            network: try values["network"].map { try string($0, path: "\(path).network") },
            process: try values["process"].map { try integer($0, path: "\(path).process") }
        )
    }

    private func decodeAcceleratorClaims(
        _ node: Node,
        path: String
    ) throws -> [HostwrightAcceleratorClaim] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure(
                "Accelerator claims must be a sequence.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        guard sequence.count <= HostwrightSchedulingPolicy.maximumAcceleratorClaims else {
            throw ManifestParser.failure(
                "Accelerator claims must contain at most \(HostwrightSchedulingPolicy.maximumAcceleratorClaims) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(child, path: itemPath, allowed: ["name", "count"])
            return HostwrightAcceleratorClaim(
                name: try requiredString(
                    values["name"],
                    path: "\(itemPath).name",
                    message: "Accelerator claim name is required."
                ),
                count: try values["count"].map {
                    try integer($0, path: "\(itemPath).count")
                } ?? 1
            )
        }
    }

    private func decodeScheduling(
        _ node: Node,
        path: String
    ) throws -> HostwrightSchedulingPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "priority", "requiredAffinity", "preferredAffinity",
                "requiredAntiAffinity", "preferredAntiAffinity", "topologySpread",
                "tolerations", "disruption", "preemption", "provider", "acceleratorClaims"
            ]
        )
        return HostwrightSchedulingPolicy(
            priority: try values["priority"].map {
                try signedInteger($0, path: "\(path).priority")
            } ?? 0,
            requiredAffinity: try values["requiredAffinity"].map {
                try decodeSelectors($0, path: "\(path).requiredAffinity")
            } ?? [],
            preferredAffinity: try values["preferredAffinity"].map {
                try decodePreferences($0, path: "\(path).preferredAffinity")
            } ?? [],
            requiredAntiAffinity: try values["requiredAntiAffinity"].map {
                try decodeSelectors($0, path: "\(path).requiredAntiAffinity")
            } ?? [],
            preferredAntiAffinity: try values["preferredAntiAffinity"].map {
                try decodePreferences($0, path: "\(path).preferredAntiAffinity")
            } ?? [],
            topologySpread: try values["topologySpread"].map {
                try decodeTopologySpreads($0, path: "\(path).topologySpread")
            } ?? [],
            tolerations: try values["tolerations"].map {
                try decodeTolerations($0, path: "\(path).tolerations")
            } ?? [],
            disruption: try values["disruption"].map {
                try decodeDisruption($0, path: "\(path).disruption")
            },
            preemption: try values["preemption"].map {
                let raw = try string($0, path: "\(path).preemption")
                guard let value = HostwrightPreemptionPolicy(rawValue: raw) else {
                    throw ManifestParser.failure(
                        "scheduling.preemption must be disabled or lower-priority.",
                        code: .manifestValidationFailed,
                        node: $0,
                        path: "\(path).preemption"
                    )
                }
                return value
            } ?? .disabled,
            provider: try values["provider"].map {
                try string($0, path: "\(path).provider")
            },
            acceleratorClaims: try values["acceleratorClaims"].map {
                try decodeAcceleratorClaims($0, path: "\(path).acceleratorClaims")
            } ?? []
        )
    }

    private func decodeSelectors(_ node: Node, path: String) throws -> [HostwrightSchedulingSelector] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Affinity rules must be a sequence.", node: node, path: path)
        }
        guard sequence.count <= HostwrightSchedulingPolicy.maximumRules else {
            throw ManifestParser.failure(
                "Affinity rules must contain at most \(HostwrightSchedulingPolicy.maximumRules) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            try decodeSelector(child, path: "\(path)[\(index)]")
        }
    }

    private func decodeSelector(_ node: Node, path: String) throws -> HostwrightSchedulingSelector {
        let values = try mapping(node, path: path, allowed: ["key", "operator", "values"])
        return try decodeSelector(values: values, path: path)
    }

    private func decodeSelector(
        values: [String: Node],
        path: String
    ) throws -> HostwrightSchedulingSelector {
        let rawOperator = try requiredString(
            values["operator"],
            path: "\(path).operator",
            message: "Affinity operator is required."
        )
        guard let operatorValue = HostwrightAffinityOperator(rawValue: rawOperator) else {
            throw ManifestParser.failure(
                "Affinity operator must be in, not-in, exists, or does-not-exist.",
                code: .manifestValidationFailed,
                node: values["operator"],
                path: "\(path).operator"
            )
        }
        return HostwrightSchedulingSelector(
            key: try requiredString(
                values["key"],
                path: "\(path).key",
                message: "Affinity key is required."
            ),
            operator: operatorValue,
            values: try values["values"].map { try strings($0, path: "\(path).values") } ?? []
        )
    }

    private func decodePreferences(
        _ node: Node,
        path: String
    ) throws -> [HostwrightSchedulingPreference] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("Affinity preferences must be a sequence.", node: node, path: path)
        }
        guard sequence.count <= HostwrightSchedulingPolicy.maximumRules else {
            throw ManifestParser.failure(
                "Affinity preferences must contain at most \(HostwrightSchedulingPolicy.maximumRules) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(child, path: itemPath, allowed: ["weight", "key", "operator", "values"])
            return HostwrightSchedulingPreference(
                weight: try requiredInteger(
                    values["weight"],
                    path: "\(itemPath).weight",
                    message: "Affinity preference weight is required."
                ),
                match: try decodeSelector(values: values, path: "\(itemPath).match")
            )
        }
    }

    private func decodeTopologySpreads(
        _ node: Node,
        path: String
    ) throws -> [HostwrightTopologySpread] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure(
                "topologySpread must be a sequence.",
                node: node,
                path: path
            )
        }
        guard sequence.count <= HostwrightSchedulingPolicy.maximumTopologySpreads else {
            throw ManifestParser.failure(
                "topologySpread must contain at most \(HostwrightSchedulingPolicy.maximumTopologySpreads) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: itemPath,
                allowed: ["topologyKey", "maxSkew", "whenUnsatisfiable"]
            )
            let rawAction = try values["whenUnsatisfiable"].map {
                try string($0, path: "\(itemPath).whenUnsatisfiable")
            } ?? HostwrightTopologyUnsatisfiableAction.doNotSchedule.rawValue
            guard let action = HostwrightTopologyUnsatisfiableAction(rawValue: rawAction) else {
                throw ManifestParser.failure(
                    "topologySpread.whenUnsatisfiable must be do-not-schedule or schedule-anyway.",
                    code: .manifestValidationFailed,
                    node: values["whenUnsatisfiable"],
                    path: "\(itemPath).whenUnsatisfiable"
                )
            }
            return HostwrightTopologySpread(
                topologyKey: try requiredString(
                    values["topologyKey"],
                    path: "\(itemPath).topologyKey",
                    message: "topologySpread.topologyKey is required."
                ),
                maxSkew: try values["maxSkew"].map {
                    try integer($0, path: "\(itemPath).maxSkew")
                } ?? 1,
                whenUnsatisfiable: action
            )
        }
    }

    private func decodeTolerations(
        _ node: Node,
        path: String
    ) throws -> [HostwrightSchedulingToleration] {
        guard case .sequence(let sequence) = node else {
            throw ManifestParser.failure("tolerations must be a sequence.", node: node, path: path)
        }
        guard sequence.count <= HostwrightSchedulingPolicy.maximumTolerations else {
            throw ManifestParser.failure(
                "tolerations must contain at most \(HostwrightSchedulingPolicy.maximumTolerations) entries.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return try sequence.enumerated().map { index, child in
            let itemPath = "\(path)[\(index)]"
            let values = try mapping(
                child,
                path: itemPath,
                allowed: ["key", "value", "effect", "operator"]
            )
            let rawOperator = try requiredString(
                values["operator"],
                path: "\(itemPath).operator",
                message: "Toleration operator is required."
            )
            guard let operatorValue = HostwrightTolerationOperator(rawValue: rawOperator) else {
                throw ManifestParser.failure(
                    "Toleration operator must be equals or exists.",
                    code: .manifestValidationFailed,
                    node: values["operator"],
                    path: "\(itemPath).operator"
                )
            }
            let rawEffect = try values["effect"].map {
                try string($0, path: "\(itemPath).effect")
            }
            let effect = try rawEffect.map { raw -> HostwrightTaintEffect in
                guard let effect = HostwrightTaintEffect(rawValue: raw) else {
                    throw ManifestParser.failure(
                        "Toleration effect must be no-schedule or no-execute.",
                        code: .manifestValidationFailed,
                        node: values["effect"],
                        path: "\(itemPath).effect"
                    )
                }
                return effect
            }
            return HostwrightSchedulingToleration(
                key: try values["key"].map { try string($0, path: "\(itemPath).key") },
                value: try values["value"].map { try string($0, path: "\(itemPath).value") },
                effect: effect,
                operator: operatorValue
            )
        }
    }

    private func decodeDisruption(
        _ node: Node,
        path: String
    ) throws -> HostwrightDisruptionPolicy {
        let values = try mapping(node, path: path, allowed: ["maxUnavailable", "minAvailable"])
        return HostwrightDisruptionPolicy(
            maxUnavailable: try values["maxUnavailable"].map {
                try integer($0, path: "\(path).maxUnavailable")
            },
            minAvailable: try values["minAvailable"].map {
                try integer($0, path: "\(path).minAvailable")
            }
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

    private func decodeProjectRestartBudget(
        _ node: Node,
        path: String
    ) throws -> HostwrightProjectRestartBudget {
        let values = try mapping(node, path: path, allowed: ["maxAttempts", "window"])
        return HostwrightProjectRestartBudget(
            maxAttempts: try values["maxAttempts"].map {
                try integer($0, path: "\(path).maxAttempts")
            } ?? 10,
            window: try duration(
                values["window"],
                default: 300,
                path: "\(path).window"
            )
        )
    }

    private func decodeMaintenance(
        _ node: Node,
        path: String
    ) throws -> HostwrightMaintenancePolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["timezone", "maximumDeferral", "windows"]
        )
        guard let timezoneNode = values["timezone"],
              let windowsNode = values["windows"] else {
            throw ManifestParser.failure(
                "maintenance requires timezone and windows.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        guard case .sequence(let sequence) = windowsNode else {
            throw ManifestParser.failure(
                "maintenance.windows must be a sequence.",
                code: .manifestValidationFailed,
                node: windowsNode,
                path: "\(path).windows"
            )
        }
        let windows = try sequence.enumerated().map { index, child in
            try decodeMaintenanceWindow(child, path: "\(path).windows[\(index)]")
        }
        return HostwrightMaintenancePolicy(
            timezone: try string(timezoneNode, path: "\(path).timezone"),
            maximumDeferral: try duration(
                values["maximumDeferral"],
                default: 86_400,
                path: "\(path).maximumDeferral"
            ),
            windows: windows.sorted { $0.id < $1.id }
        )
    }

    private func decodeMaintenanceWindow(
        _ node: Node,
        path: String
    ) throws -> HostwrightMaintenanceWindow {
        let values = try mapping(
            node,
            path: path,
            allowed: ["id", "actions", "recurring", "oneShot"]
        )
        guard let idNode = values["id"], let actionsNode = values["actions"] else {
            throw ManifestParser.failure(
                "A maintenance window requires id and actions.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        let rawActions = try strings(actionsNode, path: "\(path).actions")
        let actions = try rawActions.enumerated().map { index, raw in
            guard let action = HostwrightMaintenanceActionClass(rawValue: raw),
                  action.isElective else {
                throw ManifestParser.failure(
                    "maintenance window actions must be create, start, restart, update, or remove.",
                    code: .manifestValidationFailed,
                    node: actionsNode,
                    path: "\(path).actions[\(index)]"
                )
            }
            return action
        }
        let scheduleNodes = [values["recurring"], values["oneShot"]].compactMap { $0 }
        guard scheduleNodes.count == 1 else {
            throw ManifestParser.failure(
                "A maintenance window requires exactly one of recurring or oneShot.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        let schedule: HostwrightMaintenanceSchedule
        if let recurringNode = values["recurring"] {
            let recurring = try mapping(
                recurringNode,
                path: "\(path).recurring",
                allowed: ["weekdays", "start", "duration"]
            )
            guard let weekdaysNode = recurring["weekdays"],
                  let startNode = recurring["start"],
                  recurring["duration"] != nil else {
                throw ManifestParser.failure(
                    "A recurring maintenance window requires weekdays, start, and duration.",
                    code: .manifestValidationFailed,
                    node: recurringNode,
                    path: "\(path).recurring"
                )
            }
            let weekdays = try strings(weekdaysNode, path: "\(path).recurring.weekdays")
                .enumerated().map { index, raw in
                    guard let weekday = HostwrightMaintenanceWeekday(rawValue: raw) else {
                        throw ManifestParser.failure(
                            "Recurring weekdays must use monday through sunday.",
                            code: .manifestValidationFailed,
                            node: weekdaysNode,
                            path: "\(path).recurring.weekdays[\(index)]"
                        )
                    }
                    return weekday
                }
            schedule = .recurring(
                HostwrightRecurringMaintenanceWindow(
                    weekdays: weekdays.sorted { $0.rawValue < $1.rawValue },
                    start: try string(startNode, path: "\(path).recurring.start"),
                    duration: try duration(
                        recurring["duration"],
                        default: 0,
                        path: "\(path).recurring.duration"
                    )
                )
            )
        } else {
            let oneShotNode = values["oneShot"]!
            let oneShot = try mapping(
                oneShotNode,
                path: "\(path).oneShot",
                allowed: ["startsAt", "duration"]
            )
            guard let startsAtNode = oneShot["startsAt"],
                  oneShot["duration"] != nil else {
                throw ManifestParser.failure(
                    "A oneShot maintenance window requires startsAt and duration.",
                    code: .manifestValidationFailed,
                    node: oneShotNode,
                    path: "\(path).oneShot"
                )
            }
            schedule = .oneShot(
                HostwrightOneShotMaintenanceWindow(
                    startsAt: try string(startsAtNode, path: "\(path).oneShot.startsAt"),
                    duration: try duration(
                        oneShot["duration"],
                        default: 0,
                        path: "\(path).oneShot.duration"
                    )
                )
            )
        }
        return HostwrightMaintenanceWindow(
            id: try string(idNode, path: "\(path).id"),
            actions: actions.sorted { $0.rawValue < $1.rawValue },
            schedule: schedule
        )
    }

    private func decodeRetention(
        _ node: Node,
        path: String
    ) throws -> HostwrightRetentionPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "recoveryHorizon", "maximumDatabaseBytes", "targetDatabaseBytes",
                "classes", "holds"
            ]
        )
        guard let recoveryNode = values["recoveryHorizon"],
              let maximumNode = values["maximumDatabaseBytes"],
              let targetNode = values["targetDatabaseBytes"],
              let classesNode = values["classes"] else {
            throw ManifestParser.failure(
                "retention requires recoveryHorizon, maximumDatabaseBytes, targetDatabaseBytes, and classes.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }

        let classNames = Set(HostwrightRetentionClass.allCases.map(\.rawValue))
        let classValues = try mapping(classesNode, path: "\(path).classes", allowed: classNames)
        guard classValues.count == HostwrightRetentionClass.allCases.count else {
            throw ManifestParser.failure(
                "retention.classes must declare all ten bounded retention classes.",
                code: .manifestValidationFailed,
                node: classesNode,
                path: "\(path).classes"
            )
        }
        var classes: [HostwrightRetentionClass: HostwrightRetentionClassPolicy] = [:]
        for retentionClass in HostwrightRetentionClass.allCases {
            guard let classNode = classValues[retentionClass.rawValue] else {
                throw ManifestParser.failure(
                    "retention.classes.\(retentionClass.rawValue) is required.",
                    code: .manifestValidationFailed,
                    node: classesNode,
                    path: "\(path).classes.\(retentionClass.rawValue)"
                )
            }
            classes[retentionClass] = try decodeRetentionClassPolicy(
                classNode,
                path: "\(path).classes.\(retentionClass.rawValue)"
            )
        }

        let holds: [HostwrightRetentionHold]
        if let holdsNode = values["holds"] {
            guard case .sequence(let sequence) = holdsNode else {
                throw ManifestParser.failure(
                    "retention.holds must be a sequence.",
                    code: .manifestValidationFailed,
                    node: holdsNode,
                    path: "\(path).holds"
                )
            }
            holds = try sequence.enumerated().map { index, child in
                try decodeRetentionHold(child, path: "\(path).holds[\(index)]")
            }.sorted { $0.id < $1.id }
        } else {
            holds = []
        }

        return HostwrightRetentionPolicy(
            recoveryHorizon: try seconds(
                try string(recoveryNode, path: "\(path).recoveryHorizon"),
                node: recoveryNode,
                path: "\(path).recoveryHorizon"
            ),
            maximumDatabaseBytes: try integer(maximumNode, path: "\(path).maximumDatabaseBytes"),
            targetDatabaseBytes: try integer(targetNode, path: "\(path).targetDatabaseBytes"),
            classes: classes,
            holds: holds
        )
    }

    private func decodeRetentionClassPolicy(
        _ node: Node,
        path: String
    ) throws -> HostwrightRetentionClassPolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: ["maxAge", "maxRecords", "minimumRecords"]
        )
        guard let maxAgeNode = values["maxAge"],
              let maxRecordsNode = values["maxRecords"],
              let minimumRecordsNode = values["minimumRecords"] else {
            throw ManifestParser.failure(
                "A retention class requires maxAge, maxRecords, and minimumRecords.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        return HostwrightRetentionClassPolicy(
            maxAge: try seconds(
                try string(maxAgeNode, path: "\(path).maxAge"),
                node: maxAgeNode,
                path: "\(path).maxAge"
            ),
            maxRecords: try integer(maxRecordsNode, path: "\(path).maxRecords"),
            minimumRecords: try integer(minimumRecordsNode, path: "\(path).minimumRecords")
        )
    }

    private func decodeRetentionHold(
        _ node: Node,
        path: String
    ) throws -> HostwrightRetentionHold {
        let values = try mapping(
            node,
            path: path,
            allowed: ["id", "class", "selector", "reason", "expiresAt"]
        )
        guard let idNode = values["id"],
              let classNode = values["class"],
              let selectorNode = values["selector"],
              let reasonNode = values["reason"] else {
            throw ManifestParser.failure(
                "A retention hold requires id, class, selector, and reason.",
                code: .manifestValidationFailed,
                node: node,
                path: path
            )
        }
        let rawClass = try string(classNode, path: "\(path).class")
        guard let retentionClass = HostwrightRetentionClass(rawValue: rawClass) else {
            throw ManifestParser.failure(
                "A retention hold class must name one declared retention class.",
                code: .manifestValidationFailed,
                node: classNode,
                path: "\(path).class"
            )
        }
        return HostwrightRetentionHold(
            id: try string(idNode, path: "\(path).id"),
            retentionClass: retentionClass,
            selector: try string(selectorNode, path: "\(path).selector"),
            reason: try string(reasonNode, path: "\(path).reason"),
            expiresAt: try values["expiresAt"].map { try string($0, path: "\(path).expiresAt") }
        )
    }

    private func decodeRestart(_ node: Node, path: String) throws -> HostwrightRestart {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "policy", "maxAttempts", "window", "backoff", "maxBackoff",
                "jitter", "stableRun", "priority"
            ]
        )
        guard let policy = values["policy"] else {
            throw ManifestParser.failure("restart requires policy.", node: node, path: "\(path).policy")
        }
        return HostwrightRestart(
            policy: try enumString(policy, path: "\(path).policy"),
            maxAttempts: try values["maxAttempts"].map {
                try integer($0, path: "\(path).maxAttempts")
            } ?? 3,
            window: try duration(values["window"], default: 300, path: "\(path).window"),
            backoff: try duration(values["backoff"], default: 60, path: "\(path).backoff"),
            maxBackoff: try duration(values["maxBackoff"], default: 300, path: "\(path).maxBackoff"),
            jitter: try duration(values["jitter"], default: 0, path: "\(path).jitter"),
            stableRun: try duration(values["stableRun"], default: 60, path: "\(path).stableRun"),
            priority: try values["priority"].map {
                try integer($0, path: "\(path).priority")
            } ?? 0
        )
    }

    private func decodeUpdate(_ node: Node, path: String) throws -> HostwrightUpdatePolicy {
        let values = try mapping(
            node,
            path: path,
            allowed: [
                "strategy", "maxSurge", "maxUnavailable", "progressDeadline",
                "stableObservation"
            ]
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
            ),
            stableObservation: try duration(
                values["stableObservation"],
                default: 0,
                path: "\(path).stableObservation"
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
                } else if path.contains(".ingress.") {
                    context = "ingress"
                } else if path.contains(".hostAccess[") {
                    context = "hostAccess"
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

    private func signedInteger(_ node: Node, path: String) throws -> Int {
        guard case .scalar(let scalar) = node,
              node.tag.rawValue == Tag.Name.int.rawValue,
              scalar.string.range(of: #"^-?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              scalar.string != "-0",
              let value = Int(scalar.string)
        else {
            throw ManifestParser.failure(
                "Expected a canonical signed decimal integer.",
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
