import Foundation

public enum HostwrightEventSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

public struct HostwrightEvent: Equatable, Sendable {
    public let severity: HostwrightEventSeverity
    public let message: String

    public init(severity: HostwrightEventSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public enum SecretRedactor {
    public static let replacement = "[REDACTED]"

    public static func redact(value: String, secretKeys: [String]) -> String {
        let exactRedacted = secretKeys.reduce(value) { partial, secret in
            guard !secret.isEmpty else { return partial }
            return partial.replacingOccurrences(of: secret, with: replacement)
        }
        return exactRedacted.replacing(
            pattern: #"(?i)keychain://[A-Za-z0-9._:@/-]+"#,
            with: "keychain://\(replacement)"
        )
    }
}

private extension String {
    func replacing(pattern: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return expression.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}
