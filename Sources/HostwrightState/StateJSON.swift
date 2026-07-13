import Foundation
import HostwrightRuntime

enum StateJSON {
    static func encode(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StateStoreError.invalidRecord("State JSON payload is not a valid JSON object.")
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord("State JSON payload could not be encoded as UTF-8.")
        }
        return string
    }

    static func encodeStringArray(_ values: [String]) throws -> String {
        try encode(values)
    }

    static func redactedJSON(_ json: String, using policy: RuntimeRedactionPolicy = .default) throws -> String {
        guard let data = json.data(using: .utf8) else {
            throw StateStoreError.invalidRecord("State JSON payload is not valid UTF-8.")
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StateStoreError.invalidRecord("State JSON payload could not be decoded for redaction.")
        }
        return try encode(redact(value, using: policy))
    }

    static func isObject(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return value is [String: Any]
    }

    static func isArray(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return value is [Any]
    }

    private static func redact(_ value: Any, using policy: RuntimeRedactionPolicy) -> Any {
        if let object = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, nested) in object {
                redacted[key] = policy.isSensitiveKey(key)
                    ? policy.replacement
                    : redact(nested, using: policy)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redact($0, using: policy) }
        }
        if let string = value as? String {
            return policy.redact(string)
        }
        return value
    }
}
