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

        if manifest.services.isEmpty {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Manifest must define at least one service."))
        }

        var serviceNames = Set<String>()
        for service in manifest.services {
            validateName(service.name, field: "service name", issues: &issues)
            if !serviceNames.insert(service.name).inserted {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Duplicate service name: \(service.name)."))
            }

            if let image = service.image, !image.trimmingCharacters(in: .whitespaces).isEmpty {
                validateImage(image, serviceName: service.name, issues: &issues)
            } else {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(service.name)' must define a non-empty image."))
            }

            validateCommand(service.command, serviceName: service.name, issues: &issues)

            for port in service.ports {
                validatePort(port, serviceName: service.name, issues: &issues)
            }

            for volume in service.volumes {
                validateVolume(volume, serviceName: service.name, issues: &issues)
            }

            for (key, value) in service.env {
                validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
                validateLiteralEnvironmentValue(key: key, value: value, serviceName: service.name, issues: &issues)
            }

            for (key, reference) in service.secretEnv {
                validateEnvironmentKey(key, serviceName: service.name, issues: &issues)
                validateSecretEnvironmentReference(key: key, reference: reference, serviceName: service.name, issues: &issues)
                if service.env.keys.contains(key) {
                    issues.append(
                        ManifestIssue(
                            code: .manifestValidationFailed,
                            message: "Service '\(service.name)' environment key '\(key)' must not appear in both env and secretEnv."
                        )
                    )
                }
            }

            if let health = service.health {
                validateHealth(health, serviceName: service.name, issues: &issues)
            }

            if let restart = service.restart {
                validateRestart(restart, serviceName: service.name, issues: &issues)
            }
        }

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

    private static func validateVersion(_ version: Int?, issues: inout [ManifestIssue]) {
        guard let version else { return }

        if version == HostwrightManifest.currentVersion {
            return
        }

        if version < HostwrightManifest.currentVersion {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "Manifest version \(version) is older than supported version \(HostwrightManifest.currentVersion). Automatic downgrade or legacy conversion is unavailable."
                )
            )
            return
        }

        issues.append(
            ManifestIssue(
                code: .manifestUnsupportedFeature,
                message: "Manifest version \(version) is newer than supported version \(HostwrightManifest.currentVersion). Upgrade requires a newer Hostwright release."
            )
        )
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

    private static func validateImage(_ image: String, serviceName: String, issues: inout [ManifestIssue]) {
        if image.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not contain whitespace."))
        }
        if image.hasPrefix("-") {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' image must not begin with '-'."))
        }
    }

    private static func validateCommand(_ command: [String], serviceName: String, issues: inout [ManifestIssue]) {
        for token in command {
            if token.isEmpty {
                issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' command tokens must not be empty."))
            }

            if !token.hasPrefix("-") {
                continue
            }
            issues.append(
                ManifestIssue(
                    code: .manifestValidationFailed,
                    message: "Service '\(serviceName)' command token '\(token)' is not supported because command tokens beginning with '-' can be parsed as container CLI flags."
                )
            )
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

    private static func validateLiteralEnvironmentValue(key: String, value: String, serviceName: String, issues: inout [ManifestIssue]) {
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

    private static func validateHealth(_ health: HostwrightHealthCheck, serviceName: String, issues: inout [ManifestIssue]) {
        if health.command.isEmpty {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' health command must not be empty when health is present."))
        }

        if let interval = health.interval {
            validateDuration(interval, serviceName: serviceName, issues: &issues)
        }
    }

    private static func validateRestart(_ restart: HostwrightRestart, serviceName: String, issues: inout [ManifestIssue]) {
        let allowed = ["no", "on-failure", "unless-stopped"]
        if !allowed.contains(restart.policy) {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' restart policy must be one of: \(allowed.joined(separator: ", "))."))
        }
    }

    private static func validateDuration(_ duration: String, serviceName: String, issues: inout [ManifestIssue]) {
        guard duration.hasSuffix("s"),
              let seconds = Int(duration.dropLast()),
              seconds > 0
        else {
            issues.append(ManifestIssue(code: .manifestValidationFailed, message: "Service '\(serviceName)' health interval must be a positive seconds value like 10s."))
            return
        }
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }
}
