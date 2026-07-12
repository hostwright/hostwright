import CryptoKit
import Foundation
import HostwrightCore

public struct TeamProfileArtifact: Equatable, Sendable {
    public let profile: TeamPolicyProfile
    public let profileHash: String

    public init(profile: TeamPolicyProfile, profileHash: String) {
        self.profile = profile
        self.profileHash = profileHash
    }
}

public struct TeamApprovalArtifact: Equatable, Sendable {
    public let approval: TeamApprovalRecord
    public let approvalHash: String

    public init(approval: TeamApprovalRecord, approvalHash: String) {
        self.approval = approval
        self.approvalHash = approvalHash
    }
}

public struct TeamWorkflowBinding: Equatable, Sendable {
    public let profileIdentifier: String
    public let profileHash: String
    public let manifestHash: String
    public let planHash: String
    public let approvalID: String?
    public let approvalHash: String?
    public let approvalReviewer: String?
    public let approvalRecordedAt: String?
    public let approvalScope: TeamApprovalScope?

    public init(
        profileIdentifier: String,
        profileHash: String,
        manifestHash: String,
        planHash: String,
        approvalID: String? = nil,
        approvalHash: String? = nil,
        approvalReviewer: String? = nil,
        approvalRecordedAt: String? = nil,
        approvalScope: TeamApprovalScope? = nil
    ) {
        self.profileIdentifier = profileIdentifier
        self.profileHash = profileHash
        self.manifestHash = manifestHash
        self.planHash = planHash
        self.approvalID = approvalID
        self.approvalHash = approvalHash
        self.approvalReviewer = approvalReviewer
        self.approvalRecordedAt = approvalRecordedAt
        self.approvalScope = approvalScope
    }
}

public enum TeamWorkflowDocumentParser {
    private static let profileKeys: Set<String> = [
        "kind", "apiVersion", "identifier", "displayName", "optIn", "requiredGates", "requirements"
    ]
    private static let approvalKeys: Set<String> = [
        "kind", "apiVersion", "id", "reviewer", "decision", "scope", "recordedAt", "profileHash", "manifestHash", "planHash"
    ]

    public static func parseProfile(_ text: String) throws -> TeamProfileArtifact {
        try validateObjectKeys(text, expected: profileKeys, role: "team profile", code: .teamProfileInvalid)
        let profile: TeamPolicyProfile = try decode(text, role: "team profile", code: .teamProfileInvalid)
        let hash = try canonicalHash(profile, role: "team profile", code: .teamProfileInvalid)
        return TeamProfileArtifact(profile: profile, profileHash: hash)
    }

    public static func parseApproval(_ text: String) throws -> TeamApprovalArtifact {
        try validateObjectKeys(text, expected: approvalKeys, role: "approval record", code: .teamApprovalInvalid)
        let approval: TeamApprovalRecord = try decode(text, role: "approval record", code: .teamApprovalInvalid)
        let hash = try canonicalHash(approval, role: "approval record", code: .teamApprovalInvalid)
        return TeamApprovalArtifact(approval: approval, approvalHash: hash)
    }

    public static func manifestHash(_ text: String) -> String {
        sha256(Data(text.utf8))
    }

    private static func validateObjectKeys(
        _ text: String,
        expected: Set<String>,
        role: String,
        code: HostwrightErrorCode
    ) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [])
        } catch {
            throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: \(sanitizedDecoderError(error)).")
        }
        guard let object = value as? [String: Any] else {
            throw HostwrightDiagnostic(code: code, message: "The \(role) must be one JSON object.")
        }

        let orderedKeys = try topLevelKeys(in: text, role: role, code: code)
        var seen = Set<String>()
        if let duplicate = orderedKeys.first(where: { !seen.insert($0).inserted }) {
            throw HostwrightDiagnostic(code: code, message: "The \(role) contains duplicate field '\(duplicate)'.")
        }

        let keys = Set(object.keys)
        let unknown = keys.subtracting(expected).sorted()
        if !unknown.isEmpty {
            throw HostwrightDiagnostic(code: code, message: "The \(role) contains unsupported field(s): \(unknown.joined(separator: ", ")).")
        }
        let missing = expected.subtracting(keys).sorted()
        if !missing.isEmpty {
            throw HostwrightDiagnostic(code: code, message: "The \(role) is missing required field(s): \(missing.joined(separator: ", ")).")
        }
    }

    private static func decode<T: Decodable>(
        _ text: String,
        role: String,
        code: HostwrightErrorCode
    ) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw HostwrightDiagnostic(code: code, message: "The \(role) has invalid field types or values: \(sanitizedDecoderError(error)).")
        }
    }

    private static func canonicalHash<T: Encodable>(
        _ value: T,
        role: String,
        code: HostwrightErrorCode
    ) throws -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return sha256(try encoder.encode(value))
        } catch {
            throw HostwrightDiagnostic(code: code, message: "Could not canonicalize \(role).")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizedDecoderError(_ error: Error) -> String {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return "missing field '\(key.stringValue)' at \(codingPath(context.codingPath))"
        case let DecodingError.typeMismatch(_, context):
            return "type mismatch at \(codingPath(context.codingPath))"
        case let DecodingError.valueNotFound(_, context):
            return "missing value at \(codingPath(context.codingPath))"
        case let DecodingError.dataCorrupted(context):
            return "invalid value at \(codingPath(context.codingPath))"
        default:
            return "invalid JSON"
        }
    }

    private static func codingPath(_ path: [CodingKey]) -> String {
        path.map(\.stringValue).joined(separator: ".").isEmpty ? "root" : path.map(\.stringValue).joined(separator: ".")
    }

    private static func topLevelKeys(
        in text: String,
        role: String,
        code: HostwrightErrorCode
    ) throws -> [String] {
        let bytes = Array(text.utf8)
        var index = skipWhitespace(in: bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw HostwrightDiagnostic(code: code, message: "The \(role) must be one JSON object.")
        }
        index += 1
        var keys: [String] = []

        while true {
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else {
                throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }

            let parsedKey = try parseJSONString(in: bytes, from: index, role: role, code: code)
            keys.append(parsedKey.value)
            index = skipWhitespace(in: bytes, from: parsedKey.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
            }
            index = try skipJSONValue(in: bytes, from: index + 1, role: role, code: code)
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else {
                throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
            }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
        }

        guard skipWhitespace(in: bytes, from: index) == bytes.count else {
            throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
        }
        return keys
    }

    private static func parseJSONString(
        in bytes: [UInt8],
        from start: Int,
        role: String,
        code: HostwrightErrorCode
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid object key.")
        }
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == ascii("\\") {
                escaped = true
            } else if byte == ascii("\"") {
                let literal = Data(bytes[start...index])
                do {
                    return (try JSONDecoder().decode(String.self, from: literal), index + 1)
                } catch {
                    throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid object key.")
                }
            }
            index += 1
        }
        throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid object key.")
    }

    private static func skipJSONValue(
        in bytes: [UInt8],
        from start: Int,
        role: String,
        code: HostwrightErrorCode
    ) throws -> Int {
        var index = skipWhitespace(in: bytes, from: start)
        var objectDepth = 0
        var arrayDepth = 0
        var inString = false
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == ascii("\\") {
                    escaped = true
                } else if byte == ascii("\"") {
                    inString = false
                }
                index += 1
                continue
            }

            switch byte {
            case ascii("\""):
                inString = true
            case ascii("{"):
                objectDepth += 1
            case ascii("}"):
                if objectDepth == 0, arrayDepth == 0 {
                    return index
                }
                objectDepth -= 1
            case ascii("["):
                arrayDepth += 1
            case ascii("]"):
                arrayDepth -= 1
            case ascii(",") where objectDepth == 0 && arrayDepth == 0:
                return index
            default:
                break
            }
            index += 1
        }
        throw HostwrightDiagnostic(code: code, message: "Could not parse \(role) JSON: invalid JSON.")
    }

    private static func skipWhitespace(in bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) {
            index += 1
        }
        return index
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
