import Foundation
import HostwrightCore

public enum LocalControlRequestParser {
    public static let maximumRequestBytes = 64 * 1_024

    private static let allowedKeys: Set<String> = [
        "apiVersion",
        "requestID",
        "operation",
        "project",
        "eventType",
        "service",
        "severity",
        "limit",
        "sort"
    ]
    private static let requiredKeys: Set<String> = ["apiVersion", "requestID", "operation"]

    public static func parse(_ data: Data) throws -> LocalControlRequest {
        guard !data.isEmpty, data.count <= maximumRequestBytes else {
            throw invalid("The local control request must be non-empty and no larger than 64 KiB.")
        }
        try StrictControlJSONObject.validate(
            data,
            allowedKeys: allowedKeys,
            requiredKeys: requiredKeys,
            role: "local control request"
        )

        let request: LocalControlRequest
        do {
            request = try JSONDecoder().decode(LocalControlRequest.self, from: data)
        } catch {
            throw invalid("The local control request has invalid field types or values.")
        }
        try validate(request)
        return request
    }

    private static func validate(_ request: LocalControlRequest) throws {
        guard request.apiVersion == HostwrightContractVersions.controlAPI else {
            throw invalid("Local control API version \(request.apiVersion) is not supported.")
        }
        guard request.requestID.range(
            of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,63})$",
            options: .regularExpression
        ) != nil else {
            throw invalid("Local control requestID must contain 1-64 safe identifier characters.")
        }

        for value in [request.project, request.eventType, request.service].compactMap({ $0 }) {
            guard validFilter(value) else {
                throw invalid("Local control string filters must be non-empty bounded text without control characters.")
            }
        }
        if let severity = request.severity, !["info", "warning", "error"].contains(severity) {
            throw invalid("Local control event severity supports only info, warning, or error.")
        }
        if let sort = request.sort, !["asc", "desc"].contains(sort) {
            throw invalid("Local control event sort supports only asc or desc.")
        }
        if let limit = request.limit, !(1...1_000).contains(limit) {
            throw invalid("Local control event limit must be between 1 and 1000.")
        }

        let hasEventOnlyFilters = request.eventType != nil || request.service != nil ||
            request.severity != nil || request.limit != nil || request.sort != nil
        switch request.operation {
        case .events:
            break
        case .recovery:
            guard !hasEventOnlyFilters else {
                throw invalid("Local control recovery accepts only the optional project filter.")
            }
        case .plan, .status, .doctor:
            guard request.project == nil, !hasEventOnlyFilters else {
                throw invalid("This local control operation does not accept filters.")
            }
        }
    }

    private static func validFilter(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            trimmed.count <= 128 &&
            !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIInvalid, message: message)
    }
}

private enum StrictControlJSONObject {
    static func validate(
        _ data: Data,
        allowedKeys: Set<String>,
        requiredKeys: Set<String>,
        role: String
    ) throws {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw invalid("Could not parse \(role) JSON.")
        }
        guard let object = value as? [String: Any] else {
            throw invalid("The \(role) must be one JSON object.")
        }

        let orderedKeys = try topLevelKeys(in: data, role: role)
        var seen = Set<String>()
        if let duplicate = orderedKeys.first(where: { !seen.insert($0).inserted }) {
            let field = allowedKeys.contains(duplicate) ? " '\(duplicate)'" : ""
            throw invalid("The \(role) contains a duplicate field\(field).")
        }

        let actual = Set(object.keys)
        guard actual.isSubset(of: allowedKeys) else {
            throw invalid("The \(role) contains unsupported fields.")
        }
        guard requiredKeys.isSubset(of: actual) else {
            throw invalid("The \(role) is missing required fields.")
        }
    }

    private static func topLevelKeys(in data: Data, role: String) throws -> [String] {
        let bytes = Array(data)
        var index = skipWhitespace(in: bytes, from: 0)
        guard index < bytes.count, bytes[index] == ascii("{") else {
            throw invalid("The \(role) must be one JSON object.")
        }
        index += 1
        var keys: [String] = []

        while true {
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }

            let key = try parseJSONString(in: bytes, from: index, role: role)
            keys.append(key.value)
            index = skipWhitespace(in: bytes, from: key.nextIndex)
            guard index < bytes.count, bytes[index] == ascii(":") else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index = try skipJSONValue(in: bytes, from: index + 1, role: role)
            index = skipWhitespace(in: bytes, from: index)
            guard index < bytes.count else { throw invalid("Could not parse \(role) JSON.") }
            if bytes[index] == ascii(",") {
                index += 1
                continue
            }
            if bytes[index] == ascii("}") {
                index += 1
                break
            }
            throw invalid("Could not parse \(role) JSON.")
        }
        guard skipWhitespace(in: bytes, from: index) == bytes.count else {
            throw invalid("Could not parse \(role) JSON.")
        }
        return keys
    }

    private static func parseJSONString(
        in bytes: [UInt8],
        from start: Int,
        role: String
    ) throws -> (value: String, nextIndex: Int) {
        guard start < bytes.count, bytes[start] == ascii("\"") else {
            throw invalid("Could not parse \(role) JSON object key.")
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
                guard let value = try? JSONDecoder().decode(String.self, from: literal) else {
                    throw invalid("Could not parse \(role) JSON object key.")
                }
                return (value, index + 1)
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON object key.")
    }

    private static func skipJSONValue(in bytes: [UInt8], from start: Int, role: String) throws -> Int {
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
                if objectDepth == 0, arrayDepth == 0 { return index }
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
            guard objectDepth >= 0, arrayDepth >= 0 else {
                throw invalid("Could not parse \(role) JSON.")
            }
            index += 1
        }
        throw invalid("Could not parse \(role) JSON.")
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

    private static func invalid(_ message: String) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: .controlAPIInvalid, message: message)
    }
}
