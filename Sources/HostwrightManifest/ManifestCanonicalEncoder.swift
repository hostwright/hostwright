import Foundation

public enum ManifestCanonicalEncoder {
    public static func encode(_ manifest: HostwrightManifest) throws -> String {
        let issues = ManifestValidator.validate(manifest)
        guard issues.isEmpty else {
            throw ManifestParseError.failed(issues)
        }

        var lines = [
            "version: \(HostwrightManifest.currentVersion)",
            "project: \(quote(manifest.project ?? ""))"
        ]
        if let imagePolicy = manifest.imagePolicy {
            lines.append("imagePolicy: \(quote(imagePolicy.rawValue))")
        }
        lines.append("services:")

        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            lines.append("  \(quote(service.name)):")
            if let image = service.image {
                lines.append("    image: \(quote(image))")
            }
            if service.replicas != 1 {
                lines.append("    replicas: \(service.replicas)")
            }
            if service.platform != HostwrightPlatform() {
                lines.append("    platform:")
                lines.append("      os: \(quote(service.platform.os.rawValue))")
                lines.append("      architecture: \(quote(service.platform.architecture.rawValue))")
            }
            if let resources = service.resources {
                if resources.cpus == nil && resources.memory == nil {
                    lines.append("    resources: {}")
                } else {
                    lines.append("    resources:")
                    if let cpus = resources.cpus {
                        lines.append("      cpus: \(cpus)")
                    }
                    if let memory = resources.memory {
                        lines.append("      memory: \(quote(memory))")
                    }
                }
            }
            if let user = service.user {
                lines.append("    user: \(user)")
            }
            if let group = service.group {
                lines.append("    group: \(group)")
            }
            if let workdir = service.workdir {
                lines.append("    workdir: \(quote(workdir))")
            }
            appendArray(service.entrypoint, key: "entrypoint", indent: 4, to: &lines)
            appendArray(service.command, key: "command", indent: 4, to: &lines)
            if service.initProcess {
                lines.append("    init: true")
            }
            appendEnumMap(service.dependsOn, key: "dependsOn", to: &lines)
            appendStringMap(service.env, key: "env", to: &lines)
            appendStringMap(
                service.secretEnv.mapValues { $0.rawValue },
                key: "secretEnv",
                to: &lines
            )
            appendStringMap(service.labels, key: "labels", to: &lines)
            appendBlockArray(service.ports, key: "ports", to: &lines)
            appendBlockArray(service.volumes, key: "volumes", to: &lines)

            let probes = canonicalProbes(for: service)
            if probes.startup != nil || probes.readiness != nil || probes.liveness != nil {
                lines.append("    probes:")
                appendProbe(probes.startup, name: "startup", to: &lines)
                appendProbe(probes.readiness, name: "readiness", to: &lines)
                appendProbe(probes.liveness, name: "liveness", to: &lines)
            }
            if let restart = service.restart {
                lines.append("    restart:")
                lines.append("      policy: \(quote(restart.policy))")
            }
            if service.update != HostwrightUpdatePolicy() {
                lines.append("    update:")
                lines.append("      strategy: \(quote(service.update.strategy.rawValue))")
                lines.append("      maxSurge: \(service.update.maxSurge)")
                lines.append("      maxUnavailable: \(service.update.maxUnavailable)")
                lines.append("      progressDeadline: \(quote("\(service.update.progressDeadline)s"))")
            }
            if service.hooks.postStart != nil || service.hooks.preStop != nil {
                lines.append("    hooks:")
                appendHook(service.hooks.postStart, name: "postStart", to: &lines)
                appendHook(service.hooks.preStop, name: "preStop", to: &lines)
            }
            if service.rosetta {
                lines.append("    rosetta: true")
            }
            if service.virtualization {
                lines.append("    virtualization: true")
            }
            if service.readOnlyRootFilesystem {
                lines.append("    readOnlyRootFilesystem: true")
            }
            if let shmSize = service.shmSize {
                lines.append("    shmSize: \(quote(shmSize))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func canonicalProbes(for service: HostwrightService) -> HostwrightProbes {
        guard service.probes.liveness == nil, let health = service.health else {
            return service.probes
        }
        let rawInterval = health.interval ?? "10s"
        let interval = Int(rawInterval.dropLast()) ?? 10
        return HostwrightProbes(
            startup: service.probes.startup,
            readiness: service.probes.readiness,
            liveness: HostwrightProbe(action: .exec(health.command), interval: interval)
        )
    }

    private static func appendProbe(_ probe: HostwrightProbe?, name: String, to lines: inout [String]) {
        guard let probe else { return }
        lines.append("      \(name):")
        switch probe.action {
        case .exec(let command):
            lines.append("        exec: \(array(command))")
        case .http(let port, let path):
            lines.append("        http:")
            lines.append("          port: \(port)")
            lines.append("          path: \(quote(path))")
        case .tcp(let port):
            lines.append("        tcp:")
            lines.append("          port: \(port)")
        }
        if probe.startPeriod != 0 {
            lines.append("        startPeriod: \(quote("\(probe.startPeriod)s"))")
        }
        if probe.interval != 10 {
            lines.append("        interval: \(quote("\(probe.interval)s"))")
        }
        if probe.timeout != 3 {
            lines.append("        timeout: \(quote("\(probe.timeout)s"))")
        }
        if probe.successThreshold != 1 {
            lines.append("        successThreshold: \(probe.successThreshold)")
        }
        if probe.failureThreshold != 3 {
            lines.append("        failureThreshold: \(probe.failureThreshold)")
        }
    }

    private static func appendHook(_ hook: [String]?, name: String, to lines: inout [String]) {
        guard let hook else { return }
        lines.append("      \(name):")
        lines.append("        exec: \(array(hook))")
    }

    private static func appendEnumMap(
        _ values: [String: HostwrightDependencyCondition],
        key: String,
        to lines: inout [String]
    ) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for (mapKey, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("      \(quote(mapKey)): \(quote(value.rawValue))")
        }
    }

    private static func appendStringMap(
        _ values: [String: String],
        key: String,
        to lines: inout [String]
    ) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for (mapKey, value) in values.sorted(by: { $0.key < $1.key }) {
            lines.append("      \(quote(mapKey)): \(quote(value))")
        }
    }

    private static func appendBlockArray(_ values: [String], key: String, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for value in values {
            lines.append("      - \(quote(value))")
        }
    }

    private static func appendArray(_ values: [String], key: String, indent: Int, to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("\(String(repeating: " ", count: indent))\(key): \(array(values))")
    }

    private static func array(_ values: [String]) -> String {
        "[" + values.map(quote).joined(separator: ", ") + "]"
    }

    private static func quote(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
