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

public enum HostwrightLogSeverity: String, Codable, Comparable, Sendable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (left: HostwrightLogSeverity, right: HostwrightLogSeverity) -> Bool {
        left.rank < right.rank
    }

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        case .critical: 5
        }
    }
}

public enum HostwrightLogCategory: String, Codable, CaseIterable, Sendable {
    case cli
    case daemon
    case reconciliation
    case runtime
    case health
    case recovery
    case state
    case security
    case lifecycle
    case garbageCollection = "garbage-collection"
}

public enum HostwrightLogOutcome: String, Codable, Sendable {
    case started
    case succeeded
    case failed
    case cancelled
    case deferred
    case held
    case observed
}

public enum HostwrightLogReason: String, Codable, CaseIterable, Sendable {
    case cliStarted = "HW-OBS-101"
    case cliSucceeded = "HW-OBS-102"
    case cliFailed = "HW-OBS-103"
    case daemonStarted = "HW-OBS-110"
    case daemonStopped = "HW-OBS-111"
    case daemonFailed = "HW-OBS-112"
    case durableEventInfo = "HW-OBS-120"
    case durableEventWarning = "HW-OBS-121"
    case durableEventError = "HW-OBS-122"
    case sinkDegraded = "HW-OBS-130"

    fileprivate var requiredOutcome: HostwrightLogOutcome? {
        switch self {
        case .cliStarted, .daemonStarted:
            return .started
        case .cliSucceeded, .daemonStopped:
            return .succeeded
        case .cliFailed, .daemonFailed, .sinkDegraded:
            return .failed
        case .durableEventInfo, .durableEventWarning, .durableEventError:
            return nil
        }
    }
}

public enum HostwrightLogFieldName: String, Codable, CaseIterable, Sendable {
    case command
    case component
    case durationMilliseconds = "duration_ms"
    case eventID = "event_id"
    case eventType = "event_type"
    case exitCode = "exit_code"
    case iteration
    case mode
    case operationID = "operation_id"
    case source
    case status
}

public enum HostwrightLogFieldPrivacy: String, Codable, Sendable {
    case publicValue = "public"
    case privateValue = "private"
}

public struct HostwrightLogField: Equatable, Sendable {
    public static let maximumValueBytes = 128

    public let name: HostwrightLogFieldName
    public let privacy: HostwrightLogFieldPrivacy
    public let value: String

    public init(
        name: HostwrightLogFieldName,
        value: String,
        privacy: HostwrightLogFieldPrivacy = .privateValue,
        sensitiveValues: [String] = []
    ) {
        self.name = name
        self.privacy = privacy
        guard privacy == .publicValue else {
            self.value = "[PRIVATE]"
            return
        }
        let redacted = SecretRedactor.redact(value: value, secretKeys: sensitiveValues)
        self.value = HostwrightLogSanitizer.boundedSingleLine(
            redacted,
            maximumBytes: Self.maximumValueBytes
        )
    }
}

public enum HostwrightObservabilityError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidCorrelationID
    case invalidOperationID
    case duplicateField(HostwrightLogFieldName)
    case tooManyFields
    case misleadingOutcome
    case payloadTooLarge

    public var code: String {
        switch self {
        case .invalidCorrelationID, .invalidOperationID, .duplicateField:
            "HW-OBS-001"
        case .tooManyFields, .payloadTooLarge:
            "HW-OBS-002"
        case .misleadingOutcome:
            "HW-OBS-003"
        }
    }

    public var description: String {
        switch self {
        case .invalidCorrelationID:
            "\(code): The log correlation identifier is invalid."
        case .invalidOperationID:
            "\(code): The public log operation identifier is invalid."
        case .duplicateField(let field):
            "\(code): The log field '\(field.rawValue)' is duplicated."
        case .tooManyFields:
            "\(code): The log record exceeds the fixed field limit."
        case .misleadingOutcome:
            "\(code): The log reason code and outcome disagree."
        case .payloadTooLarge:
            "\(code): The log record exceeds the fixed payload limit."
        }
    }
}

public struct HostwrightLogRecord: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let subsystem = "dev.hostwright"
    public static let maximumFieldCount = 12
    public static let maximumPayloadBytes = 2_048
    public static let maximumActiveSignposts = 64

    public let version: Int
    public let category: HostwrightLogCategory
    public let severity: HostwrightLogSeverity
    public let reason: HostwrightLogReason
    public let correlationID: String
    public let outcome: HostwrightLogOutcome
    public let fields: [HostwrightLogField]

    public init(
        category: HostwrightLogCategory,
        severity: HostwrightLogSeverity,
        reason: HostwrightLogReason,
        correlationID: String,
        outcome: HostwrightLogOutcome,
        fields: [HostwrightLogField] = []
    ) throws {
        guard HostwrightLogSanitizer.isIdentifier(correlationID) else {
            throw HostwrightObservabilityError.invalidCorrelationID
        }
        guard fields.count <= Self.maximumFieldCount else {
            throw HostwrightObservabilityError.tooManyFields
        }
        guard Set(fields.map(\.name)).count == fields.count else {
            let duplicate = fields.map(\.name).first { name in
                fields.filter { $0.name == name }.count > 1
            } ?? .status
            throw HostwrightObservabilityError.duplicateField(duplicate)
        }
        if let requiredOutcome = reason.requiredOutcome, outcome != requiredOutcome {
            throw HostwrightObservabilityError.misleadingOutcome
        }
        if let operation = fields.first(where: { $0.name == .operationID }),
           operation.privacy == .publicValue,
           !HostwrightLogSanitizer.isIdentifier(operation.value) {
            throw HostwrightObservabilityError.invalidOperationID
        }

        version = Self.schemaVersion
        self.category = category
        self.severity = severity
        self.reason = reason
        self.correlationID = correlationID
        self.outcome = outcome
        self.fields = fields.sorted { $0.name.rawValue < $1.name.rawValue }

        guard canonicalMessage.utf8.count <= Self.maximumPayloadBytes else {
            throw HostwrightObservabilityError.payloadTooLarge
        }
    }

    public var canonicalMessage: String {
        let attributes = fields.map {
            "\($0.name.rawValue)=\(Self.quoted($0.value))"
        }.joined(separator: " ")
        let prefix = "version=\(version) reason=\(reason.rawValue) correlation=\(correlationID) outcome=\(outcome.rawValue)"
        return attributes.isEmpty ? prefix : "\(prefix) \(attributes)"
    }

    private static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public struct HostwrightLogConfiguration: Equatable, Sendable {
    public let enabled: Bool
    public let minimumSeverity: HostwrightLogSeverity

    public init(enabled: Bool = true, minimumSeverity: HostwrightLogSeverity = .info) {
        self.enabled = enabled
        self.minimumSeverity = minimumSeverity
    }

    public static let live = HostwrightLogConfiguration()
    public static let disabled = HostwrightLogConfiguration(enabled: false)
}

public enum HostwrightLogEmissionStatus: String, Equatable, Sendable {
    case emitted
    case filtered
    case disabled
    case degraded
}

public struct HostwrightLogEmission: Equatable, Sendable {
    public let status: HostwrightLogEmissionStatus
    public let reasonCode: String?

    public init(status: HostwrightLogEmissionStatus, reasonCode: String? = nil) {
        self.status = status
        self.reasonCode = reasonCode
    }
}

public protocol HostwrightLogSinking: Sendable {
    @discardableResult
    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission
}

public struct DisabledHostwrightLogSink: HostwrightLogSinking {
    public init() {}

    public func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        HostwrightLogEmission(status: .disabled)
    }
}

public enum HostwrightObservabilityContract {
    public static let durableAuthority = "sqlite-event-ledger-v1"
    public static let rotationAuthority = "macos-unified-logging"
    public static let automaticUpload = false
}

public struct HostwrightObservabilityStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let subsystem: String
    public let categories: [String]
    public let enabled: Bool
    public let minimumSeverity: String
    public let maximumFieldCount: Int
    public let maximumFieldValueBytes: Int
    public let maximumPayloadBytes: Int
    public let maximumActiveSignposts: Int
    public let durableAuthority: String
    public let rotationAuthority: String
    public let automaticUpload: Bool

    public init(configuration: HostwrightLogConfiguration) {
        schemaVersion = HostwrightLogRecord.schemaVersion
        subsystem = HostwrightLogRecord.subsystem
        categories = HostwrightLogCategory.allCases.map(\.rawValue).sorted()
        enabled = configuration.enabled
        minimumSeverity = configuration.minimumSeverity.rawValue
        maximumFieldCount = HostwrightLogRecord.maximumFieldCount
        maximumFieldValueBytes = HostwrightLogField.maximumValueBytes
        maximumPayloadBytes = HostwrightLogRecord.maximumPayloadBytes
        maximumActiveSignposts = HostwrightLogRecord.maximumActiveSignposts
        durableAuthority = HostwrightObservabilityContract.durableAuthority
        rotationAuthority = HostwrightObservabilityContract.rotationAuthority
        automaticUpload = HostwrightObservabilityContract.automaticUpload
    }
}

public enum SecretRedactor {
    public static let replacement = "[REDACTED]"
    public static let maximumInputBytes = 4_096
    public static let maximumSecretCount = 32
    public static let maximumSecretBytes = 256

    public static func redact(value: String, secretKeys: [String]) -> String {
        guard secretKeys.count <= maximumSecretCount,
              !secretKeys.contains(where: { $0.utf8.count > maximumSecretBytes }) else {
            return replacement
        }
        let boundedValue = HostwrightLogSanitizer.boundedSingleLine(
            value,
            maximumBytes: maximumInputBytes
        )
        var redacted = secretKeys.reduce(boundedValue) { partial, secret in
            guard !secret.isEmpty else { return partial }
            return partial.replacingOccurrences(of: secret, with: replacement)
        }
        let replacements: [(String, String)] = [
            (#"(?i)keychain://[A-Za-z0-9._:@/-]+"#, "keychain://\(replacement)"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer \(replacement)"),
            (#"(?i)\bBasic\s+[A-Za-z0-9+/=-]+"#, "Basic \(replacement)"),
            (#"(?i)\"(password|passwd|token|secret|credential|authorization|api[-_]?key)\"\s*:\s*\"[^\"]*\""#, "\"$1\":\"\(replacement)\""),
            (#"(?i)\b(password|passwd|token|secret|credential|authorization|api[-_]?key)\b\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#, "$1=\(replacement)"),
            (#"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"#, "scheme://\(replacement)@"),
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, replacement),
            (#"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[REDACTED_EMAIL]"),
            (#"(?<![A-Za-z0-9])/(?:Users|private|var|tmp|Volumes|Applications|Library|System)/[^\s,;\"']+"#, "[REDACTED_PATH]"),
            (#"\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b"#, "[REDACTED_IP]")
        ]
        for (pattern, template) in replacements {
            redacted = redacted.replacing(pattern: pattern, with: template)
        }
        return redacted
    }
}

enum HostwrightLogSanitizer {
    static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#, options: .regularExpression) != nil
    }

    static func boundedSingleLine(_ value: String, maximumBytes: Int) -> String {
        let boundedInput = prefix(value, maximumBytes: maximumBytes)
        let singleLine = boundedInput
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard singleLine.utf8.count > maximumBytes else { return singleLine }
        var result = ""
        for character in singleLine {
            let next = result + String(character)
            guard next.utf8.count <= maximumBytes - 3 else { break }
            result = next
        }
        return result + "..."
    }

    private static func prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes >= 3 else { return "" }
        var result = ""
        for character in value {
            let next = result + String(character)
            guard next.utf8.count <= maximumBytes else {
                return result + "..."
            }
            result = next
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
