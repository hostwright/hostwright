import Foundation
import HostwrightCore

public enum ManifestParser {
    public static let limitation = "Hostwright Phase 2 uses a restricted Hostwright manifest subset parser, not a general YAML parser."

    public static func parse(_ text: String) throws -> HostwrightManifest {
        let lines = text.components(separatedBy: .newlines)
        var manifest = HostwrightManifest(project: nil, services: [])
        var issues: [ManifestIssue] = []
        var currentServiceIndex: Int?
        var currentSection: NestedSection?
        var seenServices = false

        for (zeroBasedIndex, originalLine) in lines.enumerated() {
            let lineNumber = zeroBasedIndex + 1
            let withoutTrailingWhitespace = originalLine.trimmingTrailingWhitespace()
            let trimmed = withoutTrailingWhitespace.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if containsUnsupportedSyntax(trimmed) || originalLine.contains("\t") {
                issues.append(
                    ManifestIssue(
                        code: .manifestUnsupportedFeature,
                        message: "\(limitation) Unsupported YAML feature or tab indentation.",
                        line: lineNumber
                    )
                )
                continue
            }

            let indent = originalLine.leadingSpaceCount
            switch indent {
            case 0:
                currentServiceIndex = nil
                currentSection = nil
                if trimmed.hasPrefix("project:") {
                    manifest.project = value(after: "project:", in: trimmed)
                } else if trimmed == "services:" {
                    seenServices = true
                } else {
                    issues.append(unsupportedKey(trimmed, lineNumber: lineNumber))
                }
            case 2:
                guard seenServices else {
                    issues.append(ManifestIssue(code: .manifestParseFailed, message: "Service entries must appear under services.", line: lineNumber))
                    continue
                }
                guard trimmed.hasSuffix(":") else {
                    issues.append(ManifestIssue(code: .manifestParseFailed, message: "Expected service name ending in ':'.", line: lineNumber))
                    continue
                }
                let name = String(trimmed.dropLast())
                manifest.services.append(HostwrightService(name: name, image: nil))
                currentServiceIndex = manifest.services.count - 1
                currentSection = nil
            case 4:
                guard let serviceIndex = currentServiceIndex else {
                    issues.append(ManifestIssue(code: .manifestParseFailed, message: "Service fields must appear under a service name.", line: lineNumber))
                    continue
                }

                if trimmed == "ports:" {
                    currentSection = .ports
                } else if trimmed == "volumes:" {
                    currentSection = .volumes
                } else if trimmed == "env:" {
                    currentSection = .env
                } else if trimmed == "health:" {
                    currentSection = .health
                    if manifest.services[serviceIndex].health == nil {
                        manifest.services[serviceIndex].health = HostwrightHealthCheck()
                    }
                } else if trimmed == "restart:" {
                    currentSection = .restart
                } else if trimmed.hasPrefix("image:") {
                    manifest.services[serviceIndex].image = value(after: "image:", in: trimmed)
                    currentSection = nil
                } else if trimmed.hasPrefix("command:") {
                    manifest.services[serviceIndex].command = parseInlineArray(value(after: "command:", in: trimmed), lineNumber: lineNumber, issues: &issues)
                    currentSection = nil
                } else {
                    issues.append(unsupportedKey(trimmed, lineNumber: lineNumber))
                }
            case 6:
                guard let serviceIndex = currentServiceIndex, let section = currentSection else {
                    issues.append(ManifestIssue(code: .manifestParseFailed, message: "Nested values must appear under a supported service section.", line: lineNumber))
                    continue
                }

                switch section {
                case .ports:
                    if let item = listItem(from: trimmed) {
                        manifest.services[serviceIndex].ports.append(unquote(item))
                    } else {
                        issues.append(ManifestIssue(code: .manifestParseFailed, message: "Ports must be list items like - \"8080:8080\".", line: lineNumber))
                    }
                case .volumes:
                    if let item = listItem(from: trimmed) {
                        manifest.services[serviceIndex].volumes.append(unquote(item))
                    } else {
                        issues.append(ManifestIssue(code: .manifestParseFailed, message: "Volumes must be list items like - \"./data:/data:rw\".", line: lineNumber))
                    }
                case .env:
                    if let (key, value) = keyValue(trimmed) {
                        manifest.services[serviceIndex].env[key] = unquote(value)
                    } else {
                        issues.append(ManifestIssue(code: .manifestParseFailed, message: "Environment values must be key-value entries.", line: lineNumber))
                    }
                case .health:
                    if trimmed.hasPrefix("command:") {
                        manifest.services[serviceIndex].health?.command = parseInlineArray(value(after: "command:", in: trimmed), lineNumber: lineNumber, issues: &issues)
                    } else if trimmed.hasPrefix("interval:") {
                        manifest.services[serviceIndex].health?.interval = value(after: "interval:", in: trimmed)
                    } else {
                        issues.append(unsupportedKey(trimmed, lineNumber: lineNumber))
                    }
                case .restart:
                    if trimmed.hasPrefix("policy:") {
                        manifest.services[serviceIndex].restart = HostwrightRestart(policy: value(after: "policy:", in: trimmed))
                    } else {
                        issues.append(unsupportedKey(trimmed, lineNumber: lineNumber))
                    }
                }
            default:
                issues.append(
                    ManifestIssue(
                        code: .manifestUnsupportedFeature,
                        message: "\(limitation) Only 2-space indentation for the documented manifest shape is supported.",
                        line: lineNumber
                    )
                )
            }
        }

        if !issues.isEmpty {
            throw ManifestParseError.failed(issues)
        }

        return manifest
    }

    private enum NestedSection {
        case ports
        case volumes
        case env
        case health
        case restart
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

    private static func unsupportedKey(_ trimmed: String, lineNumber: Int) -> ManifestIssue {
        ManifestIssue(
            code: .manifestUnsupportedFeature,
            message: "\(limitation) Unsupported key or shape: \(trimmed)",
            line: lineNumber
        )
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

    private static func parseInlineArray(_ rawValue: String, lineNumber: Int, issues: inout [ManifestIssue]) -> [String] {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") && value.hasSuffix("]") else {
            issues.append(
                ManifestIssue(
                    code: .manifestUnsupportedFeature,
                    message: "\(limitation) Command arrays must use inline syntax like [\"curl\", \"-f\"].",
                    line: lineNumber
                )
            )
            return []
        }

        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }

        return inner.split(separator: ",").map { unquote(String($0).trimmingCharacters(in: .whitespaces)) }
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespaces)
        if result.count >= 2, result.first == "\"", result.last == "\"" {
            result = String(result.dropFirst().dropLast())
        }
        return result
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

