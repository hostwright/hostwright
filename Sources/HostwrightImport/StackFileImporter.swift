import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightPolicy

public enum StackImportDiagnosticSeverity: String, Equatable, Sendable {
    case warning
    case error
}

public struct StackImportDiagnostic: Equatable, Sendable {
    public let code: HostwrightErrorCode
    public let severity: StackImportDiagnosticSeverity
    public let message: String
    public let line: Int?
    public let policyReasonCode: String?

    public init(
        code: HostwrightErrorCode,
        severity: StackImportDiagnosticSeverity,
        message: String,
        line: Int? = nil,
        policyReasonCode: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.message = message
        self.line = line
        self.policyReasonCode = policyReasonCode
    }

    public var rendered: String {
        let prefix: String
        if let line {
            prefix = "\(code.rawValue): line \(line): \(severity.rawValue): "
        } else {
            prefix = "\(code.rawValue): \(severity.rawValue): "
        }
        return prefix + message
    }
}

public struct StackImportResult: Equatable, Sendable {
    public let manifest: HostwrightManifest?
    public let manifestText: String?
    public let diagnostics: [StackImportDiagnostic]

    public init(
        manifest: HostwrightManifest?,
        manifestText: String?,
        diagnostics: [StackImportDiagnostic]
    ) {
        self.manifest = manifest
        self.manifestText = manifestText
        self.diagnostics = diagnostics
    }

    public var warnings: [StackImportDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    public var errors: [StackImportDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    public var succeeded: Bool {
        errors.isEmpty && manifestText != nil
    }
}

public enum StackFileImporter {
    private static let limitation = "Hostwright imports only a narrow safe stack-file subset."
    private static let serviceUnsupportedFields: Set<String> = [
        "build",
        "depends_on",
        "deploy",
        "networks",
        "network_mode",
        "dns",
        "dns_search",
        "domainname",
        "hostname",
        "extra_hosts",
        "aliases",
        "expose",
        "secrets",
        "configs",
        "env_file",
        "container_name",
        "labels",
        "profiles",
        "pull_policy"
    ]
    private static let topLevelUnsupportedFields: Set<String> = [
        "networks",
        "volumes",
        "secrets",
        "configs"
    ]
    private static let exposureFields: Set<String> = [
        "networks",
        "network_mode",
        "dns",
        "dns_search",
        "domainname",
        "hostname",
        "extra_hosts",
        "aliases",
        "expose"
    ]

    public static func convert(_ text: String) -> StackImportResult {
        let lines = text.components(separatedBy: .newlines)
        var manifest = HostwrightManifest(version: HostwrightManifest.currentVersion, project: nil, imagePolicy: nil, services: [])
        var diagnostics: [StackImportDiagnostic] = []
        var seenServices = false
        var projectDeclaredFrom: String?
        var currentServiceIndex: Int?
        var currentSection: StackSection?
        var ignoredUnsupportedIndent: Int?

        for (zeroBasedIndex, originalLine) in lines.enumerated() {
            let lineNumber = zeroBasedIndex + 1
            let withoutTrailingWhitespace = originalLine.trimmingTrailingWhitespace()
            let trimmed = withoutTrailingWhitespace.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let indent = originalLine.leadingSpaceCount
            if let ignoredIndent = ignoredUnsupportedIndent {
                if indent > ignoredIndent {
                    continue
                }
                ignoredUnsupportedIndent = nil
            }

            if containsUnsupportedSyntax(trimmed) || originalLine.contains("\t") {
                diagnostics.append(
                    error(
                        "Unsupported YAML feature or tab indentation. \(limitation)",
                        line: lineNumber,
                        policyReasonCode: PolicyReasonCode.untrustedManifestUnsupportedField.rawValue
                    )
                )
                continue
            }

            switch indent {
            case 0:
                currentServiceIndex = nil
                currentSection = nil
                if trimmed.hasPrefix("name:") || trimmed.hasPrefix("project:") {
                    let source = fieldName(trimmed)
                    let value = value(after: "\(source):", in: trimmed)
                    if let projectDeclaredFrom, manifest.project != value {
                        diagnostics.append(error("Stack file declares both \(projectDeclaredFrom) and \(source) with different project values.", line: lineNumber))
                    } else {
                        projectDeclaredFrom = source
                        manifest.project = value
                    }
                } else if trimmed.hasPrefix("version:") {
                    diagnostics.append(
                        warning(
                            "Stack file format version is informational only; Hostwright manifest version \(HostwrightManifest.currentVersion) will be emitted.",
                            line: lineNumber
                        )
                    )
                } else if trimmed == "services:" {
                    seenServices = true
                } else {
                    diagnostics.append(unsupportedField(trimmed, context: "top-level stack file", line: lineNumber))
                    if trimmed.hasSuffix(":") {
                        ignoredUnsupportedIndent = indent
                    }
                }
            case 2:
                guard seenServices else {
                    diagnostics.append(error("Service entries must appear under services.", line: lineNumber))
                    continue
                }
                guard trimmed.hasSuffix(":") else {
                    diagnostics.append(error("Expected service name ending in ':'.", line: lineNumber))
                    continue
                }
                let name = String(trimmed.dropLast())
                manifest.services.append(HostwrightService(name: name, image: nil))
                currentServiceIndex = manifest.services.count - 1
                currentSection = nil
            case 4:
                guard let serviceIndex = currentServiceIndex else {
                    diagnostics.append(error("Service fields must appear under a service name.", line: lineNumber))
                    continue
                }
                parseServiceField(
                    trimmed,
                    lineNumber: lineNumber,
                    serviceIndex: serviceIndex,
                    manifest: &manifest,
                    diagnostics: &diagnostics,
                    currentSection: &currentSection,
                    ignoredUnsupportedIndent: &ignoredUnsupportedIndent,
                    indent: indent
                )
            case 6:
                guard let serviceIndex = currentServiceIndex, let section = currentSection else {
                    diagnostics.append(error("Nested values must appear under a supported import section.", line: lineNumber))
                    continue
                }
                parseSectionValue(
                    trimmed,
                    lineNumber: lineNumber,
                    section: section,
                    serviceIndex: serviceIndex,
                    manifest: &manifest,
                    diagnostics: &diagnostics
                )
            default:
                diagnostics.append(
                    error(
                        "Only 2-space indentation for the supported stack import subset is accepted.",
                        line: lineNumber,
                        policyReasonCode: PolicyReasonCode.untrustedManifestUnsupportedField.rawValue
                    )
                )
            }
        }

        if diagnostics.contains(where: { $0.severity == .error }) {
            return StackImportResult(manifest: nil, manifestText: nil, diagnostics: sortedDiagnostics(diagnostics))
        }

        let validationIssues = ManifestValidator.validate(manifest)
        diagnostics.append(contentsOf: validationIssues.map { issue in
            StackImportDiagnostic(
                code: issue.code,
                severity: .error,
                message: issue.message,
                line: issue.line,
                policyReasonCode: nil
            )
        })

        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return StackImportResult(manifest: nil, manifestText: nil, diagnostics: sortedDiagnostics(diagnostics))
        }

        let manifestText = HostwrightManifestEmitter.render(manifest)
        return StackImportResult(
            manifest: manifest,
            manifestText: manifestText,
            diagnostics: sortedDiagnostics(diagnostics)
        )
    }

    private enum StackSection {
        case environment
        case ports
        case volumes
        case healthcheck
        case restart
    }

    private static func parseServiceField(
        _ trimmed: String,
        lineNumber: Int,
        serviceIndex: Int,
        manifest: inout HostwrightManifest,
        diagnostics: inout [StackImportDiagnostic],
        currentSection: inout StackSection?,
        ignoredUnsupportedIndent: inout Int?,
        indent: Int
    ) {
        if trimmed == "environment:" {
            currentSection = .environment
        } else if trimmed == "ports:" {
            currentSection = .ports
        } else if trimmed == "volumes:" {
            currentSection = .volumes
        } else if trimmed == "healthcheck:" {
            currentSection = .healthcheck
        } else if trimmed == "restart:" {
            currentSection = .restart
        } else if trimmed.hasPrefix("image:") {
            manifest.services[serviceIndex].image = value(after: "image:", in: trimmed)
            currentSection = nil
        } else if trimmed.hasPrefix("command:") {
            manifest.services[serviceIndex].command = parseRequiredInlineArray(
                value(after: "command:", in: trimmed),
                lineNumber: lineNumber,
                fieldName: "command",
                diagnostics: &diagnostics
            )
            currentSection = nil
        } else if trimmed.hasPrefix("restart:") {
            manifest.services[serviceIndex].restart = HostwrightRestart(policy: value(after: "restart:", in: trimmed))
            currentSection = nil
        } else {
            diagnostics.append(unsupportedField(trimmed, context: "service", line: lineNumber))
            if trimmed.hasSuffix(":") {
                ignoredUnsupportedIndent = indent
            }
            currentSection = nil
        }
    }

    private static func parseSectionValue(
        _ trimmed: String,
        lineNumber: Int,
        section: StackSection,
        serviceIndex: Int,
        manifest: inout HostwrightManifest,
        diagnostics: inout [StackImportDiagnostic]
    ) {
        switch section {
        case .environment:
            if let (key, value) = keyValue(trimmed) {
                manifest.services[serviceIndex].env[key] = unquote(value)
            } else {
                diagnostics.append(error("Imported environment must be a key-value map, not list or interpolated syntax.", line: lineNumber))
            }
        case .ports:
            guard let item = listItem(from: trimmed) else {
                diagnostics.append(error("Imported ports must be string list items like - \"8080:8080\".", line: lineNumber))
                return
            }
            manifest.services[serviceIndex].ports.append(unquote(item))
        case .volumes:
            guard let item = listItem(from: trimmed) else {
                diagnostics.append(error("Imported volumes must be string list items like - \"./data:/data:rw\".", line: lineNumber))
                return
            }
            let volume = unquote(item)
            if let volumeError = explicitHostPathVolumeError(volume) {
                diagnostics.append(volumeError(lineNumber))
                return
            }
            manifest.services[serviceIndex].volumes.append(volume)
        case .healthcheck:
            if trimmed.hasPrefix("test:") {
                let tokens = parseRequiredInlineArray(
                    value(after: "test:", in: trimmed),
                    lineNumber: lineNumber,
                    fieldName: "healthcheck.test",
                    diagnostics: &diagnostics
                )
                guard !tokens.isEmpty else { return }
                if tokens.first == "CMD" {
                    manifest.services[serviceIndex].health = manifest.services[serviceIndex].health ?? HostwrightHealthCheck()
                    manifest.services[serviceIndex].health?.command = Array(tokens.dropFirst())
                } else {
                    diagnostics.append(
                        error(
                            "Imported healthcheck.test supports only [\"CMD\", ...] arrays; shell, NONE, and implicit command forms are unsupported.",
                            line: lineNumber,
                            policyReasonCode: PolicyReasonCode.lifecycleUnsupported.rawValue
                        )
                    )
                }
            } else if trimmed.hasPrefix("interval:") {
                manifest.services[serviceIndex].health = manifest.services[serviceIndex].health ?? HostwrightHealthCheck()
                manifest.services[serviceIndex].health?.interval = value(after: "interval:", in: trimmed)
            } else {
                diagnostics.append(unsupportedField(trimmed, context: "healthcheck", line: lineNumber))
            }
        case .restart:
            if trimmed.hasPrefix("policy:") {
                manifest.services[serviceIndex].restart = HostwrightRestart(policy: value(after: "policy:", in: trimmed))
            } else {
                diagnostics.append(unsupportedField(trimmed, context: "restart", line: lineNumber))
            }
        }
    }

    private static func explicitHostPathVolumeError(_ volume: String) -> ((Int) -> StackImportDiagnostic)? {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else {
            return nil
        }
        let source = String(parts[0])
        if source.hasPrefix("./") || source.hasPrefix("/") {
            return nil
        }
        return { line in
            error(
                "Imported volume '\(volume)' is not an explicit host path. Named volumes and parent-relative paths are unsupported by import.",
                line: line,
                policyReasonCode: PolicyReasonCode.unsafeMountSource.rawValue
            )
        }
    }

    private static func parseRequiredInlineArray(
        _ rawValue: String,
        lineNumber: Int,
        fieldName: String,
        diagnostics: inout [StackImportDiagnostic]
    ) -> [String] {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") && value.hasSuffix("]") else {
            diagnostics.append(
                error(
                    "Imported \(fieldName) must use inline array syntax.",
                    line: lineNumber,
                    policyReasonCode: PolicyReasonCode.untrustedManifestUnsupportedField.rawValue
                )
            )
            return []
        }

        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func unsupportedField(_ trimmed: String, context: String, line: Int) -> StackImportDiagnostic {
        let field = fieldName(trimmed)
        let decision: PolicyDecision
        if exposureFields.contains(field) {
            decision = LocalPolicyEvaluator.default.evaluateSecureExposureRequest(scope: field)
        } else {
            decision = LocalPolicyEvaluator.default.evaluateUntrustedManifestUnsupportedField(field: field, context: context)
        }

        let fieldScope: String
        if topLevelUnsupportedFields.contains(field) || serviceUnsupportedFields.contains(field) {
            fieldScope = "Unsupported stack-file \(context) field '\(field)'."
        } else {
            fieldScope = "Unknown stack-file \(context) field '\(field)'."
        }

        return error(
            "\(limitation) \(fieldScope) \(decision.message)",
            line: line,
            policyReasonCode: decision.reasonCode.rawValue
        )
    }

    private static func containsUnsupportedSyntax(_ trimmed: String) -> Bool {
        trimmed == "---" ||
        trimmed == "..." ||
        trimmed.contains("&") ||
        trimmed.contains("*") ||
        trimmed.contains("<<") ||
        trimmed.hasPrefix("!") ||
        trimmed.contains("{") ||
        trimmed.contains("}") ||
        trimmed.hasSuffix("|") ||
        trimmed.hasSuffix(">")
    }

    private static func warning(_ message: String, line: Int? = nil) -> StackImportDiagnostic {
        StackImportDiagnostic(code: .manifestUnsupportedFeature, severity: .warning, message: message, line: line)
    }

    private static func error(
        _ message: String,
        line: Int? = nil,
        policyReasonCode: String? = nil
    ) -> StackImportDiagnostic {
        StackImportDiagnostic(
            code: .manifestUnsupportedFeature,
            severity: .error,
            message: message,
            line: line,
            policyReasonCode: policyReasonCode
        )
    }

    private static func sortedDiagnostics(_ diagnostics: [StackImportDiagnostic]) -> [StackImportDiagnostic] {
        diagnostics.sorted { lhs, rhs in
            if (lhs.line ?? Int.max) != (rhs.line ?? Int.max) {
                return (lhs.line ?? Int.max) < (rhs.line ?? Int.max)
            }
            if lhs.severity != rhs.severity {
                return lhs.severity.rawValue < rhs.severity.rawValue
            }
            return lhs.message < rhs.message
        }
    }

    private static func fieldName(_ trimmed: String) -> String {
        let field = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        return field.trimmingCharacters(in: .whitespaces)
    }

    private static func value(after prefix: String, in line: String) -> String {
        unquote(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(from line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, rawValue)
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        if result.count >= 2, result.first == "\"", result.last == "\"" {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }
}

public enum HostwrightManifestEmitter {
    public static func render(_ manifest: HostwrightManifest) -> String {
        var lines: [String] = [
            "version: \(manifest.effectiveVersion)",
            "project: \(manifest.project ?? "")",
            "",
            "services:"
        ]

        for service in manifest.services {
            lines.append("  \(service.name):")
            if let image = service.image {
                lines.append("    image: \(image)")
            }
            if !service.command.isEmpty {
                lines.append("    command: \(inlineArray(service.command))")
            }
            if !service.ports.isEmpty {
                lines.append("    ports:")
                for port in service.ports {
                    lines.append("      - \(quoted(port))")
                }
            }
            if !service.volumes.isEmpty {
                lines.append("    volumes:")
                for volume in service.volumes {
                    lines.append("      - \(quoted(volume))")
                }
            }
            if !service.env.isEmpty {
                lines.append("    env:")
                for key in service.env.keys.sorted() {
                    lines.append("      \(key): \(scalar(service.env[key] ?? ""))")
                }
            }
            if !service.secretEnv.isEmpty {
                lines.append("    secretEnv:")
                for key in service.secretEnv.keys.sorted() {
                    lines.append("      \(key): \(service.secretEnv[key]?.rawValue ?? "")")
                }
            }
            if let health = service.health {
                lines.append("    health:")
                lines.append("      command: \(inlineArray(health.command))")
                if let interval = health.interval {
                    lines.append("      interval: \(interval)")
                }
            }
            if let restart = service.restart {
                lines.append("    restart:")
                lines.append("      policy: \(restart.policy)")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func inlineArray(_ values: [String]) -> String {
        "[" + values.map(quoted).joined(separator: ", ") + "]"
    }

    private static func scalar(_ value: String) -> String {
        let safePattern = #"^[A-Za-z0-9._:/@-]+$"#
        if !value.isEmpty, value.range(of: safePattern, options: .regularExpression) != nil {
            return value
        }
        return quoted(value)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private extension String {
    var leadingSpaceCount: Int {
        prefix { $0 == " " }.count
    }

    func trimmingTrailingWhitespace() -> String {
        var result = self
        while result.last == " " || result.last == "\t" {
            result.removeLast()
        }
        return result
    }
}
