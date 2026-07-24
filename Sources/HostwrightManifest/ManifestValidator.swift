import Foundation
import HostwrightCore
import HostwrightSecrets

public enum ManifestValidator {
    public static func validate(_ manifest: HostwrightManifest) -> [ManifestIssue] {
        var issues: [ManifestIssue] = []
        validateVersion(manifest.version, issues: &issues)

        if let project = manifest.project, !project.isEmpty {
            validateName(project, field: "project", issues: &issues)
        } else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define a non-empty project."))
        }
        guard !manifest.services.isEmpty else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define at least one service."))
            return issues
        }

        let declaredNames = Set(manifest.services.map(\.name))
        var serviceNames = Set<String>()
        for service in manifest.services {
            validateService(
                service,
                imagePolicy: manifest.effectiveImagePolicy,
                declaredNames: declaredNames,
                issues: &issues
            )
            if !serviceNames.insert(service.name).inserted {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Duplicate service name: \(service.name)."))
            }
        }
        validatePublishedPortCollisions(manifest.services, issues: &issues)
        return issues
    }

    public static func validated(_ text: String) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    public static func validated(
        _ text: String,
        cancellationCheck: @escaping @Sendable () -> Bool
    ) throws -> HostwrightManifest {
        let manifest = try ManifestParser.parse(text, cancellationCheck: cancellationCheck)
        let issues = validate(manifest)
        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }
        return manifest
    }

    private static func validateService(
        _ service: HostwrightService,
        imagePolicy: HostwrightImagePolicy,
        declaredNames: Set<String>,
        issues: inout [ManifestIssue]
    ) {
        validateName(service.name, field: "service name", issues: &issues)
        if !(1...256).contains(service.replicas) {
            issues.append(issue(service, "replicas must be between 1 and 256."))
        }

        if let image = service.image, !image.trimmingCharacters(in: .whitespaces).isEmpty {
            validateImage(image, serviceName: service.name, imagePolicy: imagePolicy, issues: &issues)
        } else {
            issues.append(issue(service, "must define a non-empty image."))
        }

        if let cpus = service.resources?.cpus, cpus <= 0 {
            issues.append(issue(service, "resources.cpus must be a positive integer."))
        }
        if let memory = service.resources?.memory {
            validateSize(memory, field: "resources.memory", service: service, issues: &issues)
        }
        if let shmSize = service.shmSize {
            validateSize(shmSize, field: "shmSize", service: service, issues: &issues)
        }

        if let workdir = service.workdir, !isNormalizedAbsoluteContainerPath(workdir) {
            issues.append(issue(service, "workdir must be a normalized absolute container path."))
        }
        validateCommand(service.entrypoint, field: "entrypoint", service: service, issues: &issues)
        validateCommand(service.command, field: "command", service: service, issues: &issues)

        for (dependency, _) in service.dependsOn.sorted(by: { $0.key < $1.key }) {
            validateName(dependency, field: "dependency name", issues: &issues)
            if dependency == service.name {
                issues.append(issue(service, "dependsOn must not reference the service itself."))
            } else if !declaredNames.contains(dependency) {
                issues.append(issue(service, "dependsOn references missing service '\(dependency)'."))
            }
        }

        for port in service.ports {
            validatePort(port, serviceName: service.name, issues: &issues)
        }
        if Set(service.ports).count != service.ports.count {
            issues.append(issue(service, "ports must not contain duplicates."))
        }
        for volume in service.volumes {
            validateVolume(volume, serviceName: service.name, issues: &issues)
        }

        for (key, value) in service.env.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateLiteralEnvironmentValue(key: key, value: value, serviceName: service.name, issues: &issues)
            validateBounded(value, maximum: 16_384, field: "env.\(key)", service: service, issues: &issues)
        }
        for (key, reference) in service.secretEnv.sorted(by: { $0.key < $1.key }) {
            validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
            validateSecretEnvironmentReference(key: key, reference: reference, serviceName: service.name, issues: &issues)
            if service.env.keys.contains(key) {
                issues.append(issue(service, "environment key '\(key)' must not appear in both env and secretEnv."))
            }
        }
        validateLabels(service.labels, service: service, issues: &issues)

        if let health = service.health {
            validateHealth(health, serviceName: service.name, issues: &issues)
        }
        validateProbe(service.probes.startup, name: "startup", service: service, issues: &issues)
        validateProbe(service.probes.readiness, name: "readiness", service: service, issues: &issues)
        validateProbe(service.probes.liveness, name: "liveness", service: service, issues: &issues)

        if let restart = service.restart {
            validateRestart(restart, serviceName: service.name, issues: &issues)
        }
        validateUpdate(service.update, replicas: service.replicas, service: service, issues: &issues)
        validateHook(service.hooks.postStart, name: "postStart", service: service, issues: &issues)
        validateHook(service.hooks.preStop, name: "preStop", service: service, issues: &issues)

        if service.rosetta && service.platform.architecture != .amd64 {
            issues.append(issue(service, "rosetta requires platform.architecture amd64."))
        }
        if service.rosetta && !service.virtualization {
            issues.append(issue(service, "rosetta requires virtualization."))
        }
    }

    private static func validateVersion(_ version: Int?, issues: inout [ManifestIssue]) {
        guard let version else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest must declare version: \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' for legacy manifests."
                )
            )
            return
        }
        guard version != HostwrightManifest.currentVersion else { return }
        if version < HostwrightManifest.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is older than supported version \(HostwrightManifest.currentVersion). Run 'hostwright migrate preview' to inspect the required conversion."
                )
            )
        } else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is newer than supported version \(HostwrightManifest.currentVersion). Upgrade requires a newer Hostwright release."
                )
            )
        }
    }

    private static func validateName(_ value: String, field: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#
        if value.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "\(field) '\(value)' must be lowercase DNS-like text: letters, numbers, hyphens, no leading or trailing hyphen."
                )
            )
        }
    }

    private static func validateImage(
        _ image: String,
        serviceName: String,
        imagePolicy: HostwrightImagePolicy,
        issues: inout [ManifestIssue]
    ) {
        if image.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not contain whitespace."))
        }
        if image.hasPrefix("-") {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not begin with '-'."))
        }
        issues.append(contentsOf: ImageReferencePolicy.validate(image, serviceName: serviceName, policy: imagePolicy))
    }

    private static func validateCommand(
        _ command: [String],
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard command.count <= 1_024 else {
            issues.append(issue(service, "\(field) exceeds 1,024 arguments."))
            return
        }
        for token in command {
            if token.isEmpty {
                issues.append(issue(service, "\(field) tokens must not be empty."))
            } else {
                validateBounded(token, maximum: 16_384, field: field, service: service, issues: &issues)
            }
        }
    }

    private static func validatePort(_ port: String, serviceName: String, issues: inout [ManifestIssue]) {
        let parts = port.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let published = Int(parts[0]),
              let target = Int(parts[1]),
              isValidPort(published),
              isValidPort(target)
        else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' port '\(port)' must use \"host:container\" with ports between 1 and 65535."
                )
            )
            return
        }
    }

    private static func validatePublishedPortCollisions(
        _ services: [HostwrightService],
        issues: inout [ManifestIssue]
    ) {
        var ownersByPort: [Int: Set<String>] = [:]

        for service in services.sorted(by: { $0.name < $1.name }) {
            let publishedPorts = service.ports.compactMap(validPublishedPort)
            let uniquePorts = Set(publishedPorts)

            if service.replicas > 1, !uniquePorts.isEmpty {
                let ports = uniquePorts.sorted().map(String.init).joined(separator: ", ")
                issues.append(
                    issue(
                        service,
                        "replicas cannot share fixed localhost ports: \(ports)."
                    )
                )
            }

            for port in uniquePorts {
                ownersByPort[port, default: []].insert(service.name)
            }

            let counts = Dictionary(
                grouping: publishedPorts,
                by: { $0 }
            ).mapValues(\.count)
            for port in counts.keys.sorted() where counts[port, default: 0] > 1 {
                issues.append(
                    issue(
                        service,
                        "publishes fixed localhost port \(port) more than once."
                    )
                )
            }
        }

        for port in ownersByPort.keys.sorted() {
            let owners = ownersByPort[port, default: []].sorted()
            guard owners.count > 1 else { continue }
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Fixed localhost port \(port) is published by multiple services: \(owners.joined(separator: ", "))."
                )
            )
        }
    }

    private static func validPublishedPort(_ value: String) -> Int? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let published = Int(parts[0]),
              let target = Int(parts[1]),
              isValidPort(published),
              isValidPort(target) else {
            return nil
        }
        return published
    }

    private static func validateVolume(_ volume: String, serviceName: String, issues: inout [ManifestIssue]) {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[1].hasPrefix("/")
        else {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' volume '\(volume)' must use source:/absolute/container/path[:ro|rw]."
                )
            )
            return
        }
        if parts.count == 3 && parts[2] != "ro" && parts[2] != "rw" {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' mode must be ro or rw."))
        }
        let source = String(parts[0])
        if HostwrightPathPolicy.isHostRootMountSource(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' must not mount the host root."))
        }
        if HostwrightPathPolicy.containsParentDirectoryTraversal(source) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' source must not contain parent-directory traversal."))
        }
        if !isNormalizedAbsoluteContainerPath(String(parts[1])) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' volume '\(volume)' container path must be normalized."))
        }
    }

    private static func validateEnvironmentKey(_ key: String, serviceName: String, issues: inout [ManifestIssue]) {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        if key.range(of: pattern, options: .regularExpression) == nil {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' must use shell-safe letters, numbers, and underscores, and must not start with a number."
                )
            )
        }
    }

    private static func validateLiteralEnvironmentValue(
        key: String,
        value: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if value.hasPrefix("\(HostwrightSecretReference.supportedScheme)://") {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' uses a secret reference in env; move it to secretEnv."
                )
            )
        }
        if SecretNamePolicy.requiresSecretReferenceEnvironmentKey(key) {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' environment key '\(key)' looks sensitive; plaintext sensitive values must use secretEnv."
                )
            )
        }
    }

    private static func validateSecretEnvironmentReference(
        key: String,
        reference: HostwrightSecretReference,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        do {
            _ = try HostwrightSecretReference.parse(reference.rawValue)
        } catch {
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' secretEnv key '\(key)' must use keychain://<service>/<account>."
                )
            )
        }
    }

    private static func validateLabels(
        _ labels: [String: String],
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if labels.count > 256 {
            issues.append(issue(service, "labels exceed the limit of 256 entries."))
        }
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("dev.hostwright.") {
                issues.append(issue(service, "label '\(key)' uses the reserved Hostwright ownership prefix."))
            }
            validateBounded(key, maximum: 128, field: "label key", service: service, issues: &issues)
            validateBounded(value, maximum: 4_096, field: "label '\(key)'", service: service, issues: &issues)
        }
    }

    private static func validateHealth(
        _ health: HostwrightHealthCheck,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        if health.command.isEmpty {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' health command must not be empty when health is present."))
        }
        if let interval = health.interval {
            validatePositiveDuration(interval, field: "health interval", serviceName: serviceName, issues: &issues)
        }
    }

    private static func validateProbe(
        _ probe: HostwrightProbe?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let probe else { return }
        switch probe.action {
        case .exec(let command):
            if command.isEmpty {
                issues.append(issue(service, "probes.\(name).exec must not be empty."))
            }
            validateCommand(command, field: "probes.\(name).exec", service: service, issues: &issues)
        case .http(let port, let path):
            validateProbePort(port, name: name, service: service, issues: &issues)
            if !isNormalizedAbsoluteContainerPath(path) {
                issues.append(issue(service, "probes.\(name).http.path must be a normalized absolute loopback path."))
            }
        case .tcp(let port):
            validateProbePort(port, name: name, service: service, issues: &issues)
        }
        if probe.startPeriod < 0 || probe.interval <= 0 || probe.timeout <= 0
            || probe.successThreshold <= 0 || probe.failureThreshold <= 0 {
            issues.append(issue(service, "probes.\(name) timing and thresholds must be positive; startPeriod may be zero."))
        }
    }

    private static func validateProbePort(
        _ port: Int,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let declaredTargets = Set(service.ports.compactMap { value -> Int? in
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count == 2 ? Int(fields[1]) : nil
        })
        if !isValidPort(port) || !declaredTargets.contains(port) {
            issues.append(issue(service, "probes.\(name) port \(port) must reference a declared service container port."))
        }
    }

    private static func validateRestart(
        _ restart: HostwrightRestart,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        let allowed = ["no", "on-failure", "unless-stopped"]
        if !allowed.contains(restart.policy) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart policy must be one of: \(allowed.joined(separator: ", "))."))
        }
    }

    private static func validateUpdate(
        _ update: HostwrightUpdatePolicy,
        replicas: Int,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if update.maxSurge < 0 || update.maxUnavailable < 0 {
            issues.append(issue(service, "update maxSurge and maxUnavailable must be non-negative."))
        }
        if update.strategy == .rolling && update.maxSurge == 0 && update.maxUnavailable == 0 {
            issues.append(issue(service, "rolling update requires maxSurge or maxUnavailable to be positive."))
        }
        if update.maxUnavailable > replicas {
            issues.append(issue(service, "update.maxUnavailable must not exceed replicas."))
        }
        if update.progressDeadline <= 0 {
            issues.append(issue(service, "update.progressDeadline must be positive."))
        }
    }

    private static func validateHook(
        _ hook: [String]?,
        name: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        guard let hook else { return }
        if hook.isEmpty {
            issues.append(issue(service, "hooks.\(name).exec must not be empty."))
        }
        validateCommand(hook, field: "hooks.\(name).exec", service: service, issues: &issues)
    }

    private static func validateSize(
        _ value: String,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        let pattern = #"^[1-9][0-9]*(B|KiB|MiB|GiB|TiB)$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            issues.append(issue(service, "\(field) must be a normalized positive size such as 512MiB."))
            return
        }

        let suffixes: [(String, UInt64)] = [
            ("TiB", 1_099_511_627_776),
            ("GiB", 1_073_741_824),
            ("MiB", 1_048_576),
            ("KiB", 1_024),
            ("B", 1)
        ]
        guard let (suffix, multiplier) = suffixes.first(where: {
            value.hasSuffix($0.0)
        }),
            let count = UInt64(value.dropLast(suffix.count)),
            !count.multipliedReportingOverflow(by: multiplier).overflow else {
            issues.append(issue(service, "\(field) exceeds UInt64 byte capacity."))
            return
        }
    }

    private static func validateBounded(
        _ value: String,
        maximum: Int,
        field: String,
        service: HostwrightService,
        issues: inout [ManifestIssue]
    ) {
        if value.utf8.count > maximum {
            issues.append(issue(service, "\(field) exceeds \(maximum) UTF-8 bytes."))
        }
    }

    private static func validatePositiveDuration(
        _ duration: String,
        field: String,
        serviceName: String,
        issues: inout [ManifestIssue]
    ) {
        guard duration.hasSuffix("s"),
              let seconds = Int(duration.dropLast()),
              seconds > 0,
              String(seconds) == duration.dropLast()
        else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' \(field) must be a positive seconds value like 10s."))
            return
        }
    }

    private static func isNormalizedAbsoluteContainerPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value != "/", !value.contains("//") else {
            return value == "/"
        }
        return value.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func issue(_ service: HostwrightService, _ message: String) -> ManifestIssue {
        ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' \(message)")
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }
}
