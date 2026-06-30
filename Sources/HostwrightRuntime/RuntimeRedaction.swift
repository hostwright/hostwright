import Foundation

public struct RuntimeRedactionPolicy: Equatable, Sendable {
    public let replacement: String
    public let sensitiveKeyFragments: [String]

    public init(replacement: String = "[REDACTED]", sensitiveKeyFragments: [String]) {
        self.replacement = replacement
        self.sensitiveKeyFragments = sensitiveKeyFragments
    }

    public static let `default` = RuntimeRedactionPolicy(
        sensitiveKeyFragments: [
            "TOKEN",
            "PASSWORD",
            "PASS",
            "SECRET",
            "CREDENTIAL",
            "AUTH",
            "KEY"
        ]
    )

    public func isSensitiveKey(_ key: String) -> Bool {
        let uppercased = key.uppercased()
        return sensitiveKeyFragments.contains { uppercased.contains($0) }
    }

    public func redact(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #"(?i)(password|passwd|token|secret|credential|authorization|auth)[=:]\s*([^\s,;]+)"#,
            #"(?i)(bearer)\s+([A-Za-z0-9._~+/=-]+)"#
        ]

        for pattern in patterns {
            redacted = redacted.replacing(pattern: pattern, with: "$1=\(replacement)")
        }

        return redacted
    }

    public func redact(arguments: [String]) -> [String] {
        arguments.map { redact($0) }
    }

    public func redact(environment: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in environment {
            result[key] = isSensitiveKey(key) ? replacement : redact(value)
        }
        return result
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
