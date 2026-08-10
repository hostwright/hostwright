import Foundation

public enum SchedulerValidationErrorCode: String, Codable, Equatable, Hashable, Sendable {
    case invalidResourceName = "invalid-resource-name"
    case negativeResourceValue = "negative-resource-value"
    case arithmeticOverflow = "arithmetic-overflow"
    case arithmeticUnderflow = "arithmetic-underflow"
    case invalidField = "invalid-field"
    case invalidStringCollection = "invalid-string-collection"
    case invalidLimit = "invalid-limit"
    case invalidAllocation = "invalid-allocation"
    case invalidAffinity = "invalid-affinity"
    case invalidTaint = "invalid-taint"
    case invalidToleration = "invalid-toleration"
}

public enum SchedulerValidationError:
    Error,
    Equatable,
    Hashable,
    Sendable,
    CustomStringConvertible
{
    case invalidResourceName(String)
    case negativeResourceValue(resource: String, value: Int64)
    case arithmeticOverflow(resource: String)
    case arithmeticUnderflow(resource: String)
    case invalidField(String)
    case invalidStringCollection(field: String, value: String)
    case limitBelowRequest(resource: String)
    case allocationExceedsCapacity(resource: String)
    case invalidAffinity(String)
    case invalidTaint(String)
    case invalidToleration(String)

    public var code: SchedulerValidationErrorCode {
        switch self {
        case .invalidResourceName:
            .invalidResourceName
        case .negativeResourceValue:
            .negativeResourceValue
        case .arithmeticOverflow:
            .arithmeticOverflow
        case .arithmeticUnderflow:
            .arithmeticUnderflow
        case .invalidField:
            .invalidField
        case .invalidStringCollection:
            .invalidStringCollection
        case .limitBelowRequest:
            .invalidLimit
        case .allocationExceedsCapacity:
            .invalidAllocation
        case .invalidAffinity:
            .invalidAffinity
        case .invalidTaint:
            .invalidTaint
        case .invalidToleration:
            .invalidToleration
        }
    }

    public var stableKey: String {
        switch self {
        case .invalidResourceName(let value):
            code.rawValue + ":" + value
        case .negativeResourceValue(let resource, let value):
            code.rawValue + ":" + resource + ":" + String(value)
        case .arithmeticOverflow(let resource),
             .arithmeticUnderflow(let resource),
             .limitBelowRequest(let resource),
             .allocationExceedsCapacity(let resource):
            code.rawValue + ":" + resource
        case .invalidField(let field):
            code.rawValue + ":" + field
        case .invalidStringCollection(let field, let value):
            code.rawValue + ":" + field + ":" + value
        case .invalidAffinity(let detail),
             .invalidTaint(let detail),
             .invalidToleration(let detail):
            code.rawValue + ":" + detail
        }
    }

    public var description: String {
        stableKey
    }
}

public enum SchedulerOrdering {
    public static func uuidKey(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    public static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        uuidKey(lhs) < uuidKey(rhs)
    }

    /// Returns a deterministic, printable key for validated contract fields.
    /// Delimiters and non-ASCII/control bytes are escaped so the key can also
    /// be carried in bounded explanation and filter-detail strings.
    public static func stableKey(_ components: [String]) -> String {
        components.map(escapeStableKeyComponent).joined(separator: "|")
    }

    private static func escapeStableKeyComponent(_ value: String) -> String {
        value.utf8.reduce(into: String()) { result, byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a,
                 0x2d, 0x2e, 0x2f, 0x3a, 0x5f:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result.append(String(format: "%%%02x", Int(byte)))
            }
        }
    }
}

internal enum SchedulerCanonicalization {
    static func resourceName(_ value: String) throws -> String {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !containsControlCharacter(value) else {
            throw SchedulerValidationError.invalidResourceName(value)
        }
        return value
    }

    static func identifier(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !containsControlCharacter(value) else {
            throw SchedulerValidationError.invalidField(field)
        }
        return value
    }

    static func optionalIdentifier(
        _ value: String?,
        field: String
    ) throws -> String? {
        guard let value else {
            return nil
        }
        return try identifier(value, field: field)
    }

    static func stringList(
        _ values: [String],
        field: String
    ) throws -> [String] {
        var canonical: [String] = []
        canonical.reserveCapacity(values.count)
        for value in values {
            guard !value.isEmpty else {
                throw SchedulerValidationError.invalidStringCollection(
                    field: field,
                    value: value
                )
            }
            guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !containsControlCharacter(value) else {
                throw SchedulerValidationError.invalidField(field)
            }
            canonical.append(value)
        }
        return Array(Set(canonical)).sorted()
    }

    static func labels(
        _ labels: [String: String],
        field: String
    ) throws -> [String: String] {
        var canonical: [String: String] = [:]
        for key in labels.keys.sorted() {
            guard !key.isEmpty,
                  key == key.trimmingCharacters(in: .whitespacesAndNewlines),
                  !containsControlCharacter(key) else {
                throw SchedulerValidationError.invalidField(field + "-key")
            }
            guard let value = labels[key],
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !containsControlCharacter(value) else {
                throw SchedulerValidationError.invalidField(field + "-value")
            }
            canonical[key] = value
        }
        return canonical
    }

    static func optionalText(
        _ value: String?,
        field: String
    ) throws -> String? {
        guard let value else {
            return nil
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !containsControlCharacter(value) else {
            throw SchedulerValidationError.invalidField(field)
        }
        return value
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

internal struct SchedulerDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        return nil
    }
}
