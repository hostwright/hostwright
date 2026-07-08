import Foundation

public struct RestrictedYAMLParseIssue: Equatable, Sendable {
    public let message: String
    public let line: Int

    public init(message: String, line: Int) {
        self.message = message
        self.line = line
    }
}

public struct RestrictedYAMLScalarParseResult: Equatable, Sendable {
    public let value: String?
    public let issues: [RestrictedYAMLParseIssue]

    public init(value: String?, issues: [RestrictedYAMLParseIssue]) {
        self.value = value
        self.issues = issues
    }
}

public struct RestrictedYAMLArrayParseResult: Equatable, Sendable {
    public let values: [String]
    public let issues: [RestrictedYAMLParseIssue]

    public init(values: [String], issues: [RestrictedYAMLParseIssue]) {
        self.values = values
        self.issues = issues
    }
}

public enum RestrictedYAMLSubsetParser {
    public static func containsUnsupportedSyntax(_ trimmed: String) -> Bool {
        trimmed == "---" ||
            trimmed == "..." ||
            containsUnquotedUnsupportedIndicator(in: trimmed) ||
            trimmed.hasPrefix("!") ||
            trimmed.hasSuffix("|") ||
            trimmed.hasSuffix(">")
    }

    public static func parseScalar(
        _ rawValue: String,
        lineNumber: Int,
        subject: String,
        limitation: String
    ) -> RestrictedYAMLScalarParseResult {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            return RestrictedYAMLScalarParseResult(value: "", issues: [])
        }

        if value.first == "\"" || value.first == "'" {
            var index = value.startIndex
            let quoted = parseQuotedScalarValue(value, index: &index, lineNumber: lineNumber, subject: subject, limitation: limitation)
            guard let parsed = quoted.value else {
                return RestrictedYAMLScalarParseResult(value: nil, issues: quoted.issues)
            }
            skipSpaces(in: value, index: &index)
            guard index == value.endIndex else {
                return RestrictedYAMLScalarParseResult(
                    value: nil,
                    issues: [
                        RestrictedYAMLParseIssue(
                            message: "\(limitation) \(subject) has unexpected characters after a quoted scalar.",
                            line: lineNumber
                        )
                    ]
                )
            }
            return RestrictedYAMLScalarParseResult(value: parsed, issues: [])
        }

        if containsUnsupportedSyntax(value) {
            return RestrictedYAMLScalarParseResult(
                value: nil,
                issues: [
                    RestrictedYAMLParseIssue(
                        message: "\(limitation) Unsupported YAML feature in \(subject).",
                        line: lineNumber
                    )
                ]
            )
        }

        return RestrictedYAMLScalarParseResult(value: value, issues: [])
    }

    public static func parseInlineArray(
        _ rawValue: String,
        lineNumber: Int,
        subject: String,
        limitation: String
    ) -> RestrictedYAMLArrayParseResult {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("[") && value.hasSuffix("]") else {
            return RestrictedYAMLArrayParseResult(
                values: [],
                issues: [
                    RestrictedYAMLParseIssue(
                        message: "\(limitation) \(subject) must use inline array syntax.",
                        line: lineNumber
                    )
                ]
            )
        }

        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else {
            return RestrictedYAMLArrayParseResult(values: [], issues: [])
        }

        var tokens: [String] = []
        var issues: [RestrictedYAMLParseIssue] = []
        var index = inner.startIndex

        while index < inner.endIndex {
            skipSpaces(in: inner, index: &index)
            guard index < inner.endIndex else { break }

            let token: String
            if inner[index] == "\"" || inner[index] == "'" {
                let parsed = parseQuotedScalarValue(inner, index: &index, lineNumber: lineNumber, subject: subject, limitation: limitation)
                guard let parsedValue = parsed.value else {
                    return RestrictedYAMLArrayParseResult(values: [], issues: parsed.issues)
                }
                token = parsedValue
                skipSpaces(in: inner, index: &index)
                if index < inner.endIndex, inner[index] != "," {
                    issues.append(
                        RestrictedYAMLParseIssue(
                            message: "\(limitation) \(subject) has unexpected characters after a quoted value.",
                            line: lineNumber
                        )
                    )
                    return RestrictedYAMLArrayParseResult(values: [], issues: issues)
                }
            } else {
                let start = index
                while index < inner.endIndex, inner[index] != "," {
                    index = inner.index(after: index)
                }
                let parsed = parseScalar(
                    String(inner[start..<index]).trimmingCharacters(in: .whitespaces),
                    lineNumber: lineNumber,
                    subject: subject,
                    limitation: limitation
                )
                guard let parsedValue = parsed.value else {
                    return RestrictedYAMLArrayParseResult(values: [], issues: parsed.issues)
                }
                token = parsedValue
            }

            guard !token.isEmpty else {
                issues.append(RestrictedYAMLParseIssue(message: "\(limitation) \(subject) tokens must not be empty.", line: lineNumber))
                return RestrictedYAMLArrayParseResult(values: [], issues: issues)
            }
            tokens.append(token)

            skipSpaces(in: inner, index: &index)
            if index == inner.endIndex {
                break
            }
            guard inner[index] == "," else {
                issues.append(RestrictedYAMLParseIssue(message: "\(limitation) \(subject) must separate values with commas.", line: lineNumber))
                return RestrictedYAMLArrayParseResult(values: [], issues: issues)
            }
            index = inner.index(after: index)
            skipSpaces(in: inner, index: &index)
            if index == inner.endIndex {
                issues.append(RestrictedYAMLParseIssue(message: "\(limitation) \(subject) must not end with a trailing comma.", line: lineNumber))
                return RestrictedYAMLArrayParseResult(values: [], issues: issues)
            }
        }

        return RestrictedYAMLArrayParseResult(values: tokens, issues: issues)
    }

    private static func containsUnquotedUnsupportedIndicator(in value: String) -> Bool {
        var index = value.startIndex
        var previousCharacter: Character?
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapingDoubleQuote = false

        while index < value.endIndex {
            let character = value[index]

            if inDoubleQuote {
                if escapingDoubleQuote {
                    escapingDoubleQuote = false
                } else if character == "\\" {
                    escapingDoubleQuote = true
                } else if character == "\"" {
                    inDoubleQuote = false
                }
                previousCharacter = character
                index = value.index(after: index)
                continue
            }

            if inSingleQuote {
                if character == "'" {
                    let nextIndex = value.index(after: index)
                    if nextIndex < value.endIndex, value[nextIndex] == "'" {
                        previousCharacter = character
                        index = value.index(after: nextIndex)
                        continue
                    }
                    inSingleQuote = false
                }
                previousCharacter = character
                index = value.index(after: index)
                continue
            }

            if character == "\"" {
                inDoubleQuote = true
            } else if character == "'" {
                inSingleQuote = true
            } else if character == "&" || character == "*" || character == "{" || character == "}" {
                return true
            } else if character == "<", previousCharacter == "<" {
                return true
            }

            previousCharacter = character
            index = value.index(after: index)
        }

        return false
    }

    private static func parseQuotedScalarValue(
        _ value: String,
        index: inout String.Index,
        lineNumber: Int,
        subject: String,
        limitation: String
    ) -> RestrictedYAMLScalarParseResult {
        let quote = value[index]
        guard quote == "\"" || quote == "'" else {
            return RestrictedYAMLScalarParseResult(value: nil, issues: [])
        }
        index = value.index(after: index)
        var result = ""

        if quote == "\"" {
            return parseDoubleQuotedScalarValue(value, index: &index, lineNumber: lineNumber, subject: subject, limitation: limitation, result: result)
        }

        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)
            if character == "'" {
                if index < value.endIndex, value[index] == "'" {
                    result.append("'")
                    index = value.index(after: index)
                    continue
                }
                return RestrictedYAMLScalarParseResult(value: result, issues: [])
            }
            result.append(character)
        }

        return RestrictedYAMLScalarParseResult(
            value: nil,
            issues: [RestrictedYAMLParseIssue(message: "\(limitation) \(subject) has an unterminated quoted scalar.", line: lineNumber)]
        )
    }

    private static func parseDoubleQuotedScalarValue(
        _ value: String,
        index: inout String.Index,
        lineNumber: Int,
        subject: String,
        limitation: String,
        result initialResult: String
    ) -> RestrictedYAMLScalarParseResult {
        var result = initialResult
        var escaping = false
        while index < value.endIndex {
            let character = value[index]
            index = value.index(after: index)

            if escaping {
                switch character {
                case "\"", "\\", "/":
                    result.append(character)
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                default:
                    return RestrictedYAMLScalarParseResult(
                        value: nil,
                        issues: [RestrictedYAMLParseIssue(message: "\(limitation) \(subject) contains an unsupported escape sequence.", line: lineNumber)]
                    )
                }
                escaping = false
                continue
            }

            if character == "\\" {
                escaping = true
                continue
            }

            if character == "\"" {
                return RestrictedYAMLScalarParseResult(value: result, issues: [])
            }

            result.append(character)
        }

        return RestrictedYAMLScalarParseResult(
            value: nil,
            issues: [RestrictedYAMLParseIssue(message: "\(limitation) \(subject) has an unterminated quoted scalar.", line: lineNumber)]
        )
    }

    private static func skipSpaces(in value: String, index: inout String.Index) {
        while index < value.endIndex, value[index] == " " {
            index = value.index(after: index)
        }
    }
}
