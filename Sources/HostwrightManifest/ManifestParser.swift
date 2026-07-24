import Foundation
import HostwrightCore
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
            allowed: ["version", "project", "imagePolicy", "services"]
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
        let services = try values["services"].map(decodeServices) ?? []
        return HostwrightManifest(
            version: version,
            project: project,
            imagePolicy: imagePolicy,
            services: services
        )
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
                "ports", "volumes", "health", "probes", "restart", "update", "hooks",
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
        let ports = try values["ports"].map { try strings($0, path: "\(path).ports") } ?? []
        let volumes = try values["volumes"].map { try strings($0, path: "\(path).volumes") } ?? []
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
            volumes: volumes,
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
                    "Secret environment reference for '\(key)' must use keychain://<service>/<account>.",
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

    private func mapping(_ node: Node, path: String, allowed: Set<String>) throws -> [String: Node] {
        var result: [String: Node] = [:]
        for pair in try rawMapping(node, path: path) {
            let key = try keyString(pair.key, path: path)
            guard allowed.contains(key) else {
                let context: String
                if path == "$" {
                    context = "top-level manifest"
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
