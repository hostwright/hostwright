import Foundation
import HostwrightObservability
import HostwrightRuntime

enum StateJSON {
    private static let nonSecretStructuredKeys: Set<String> = [
        "hostwrightAuthority",
        "localLeaseAuthority"
    ]

    private static let nonSecretIdentityKeys: Set<String> = [
        "authorizationPlanSHA256",
        "capabilitySHA256",
        "checkpoint",
        "confirmationToken",
        "errorCode",
        "fencingToken",
        "operationID",
        "planHash",
        "projectResourceUUID",
        "projectUUID",
        "resourceFencingToken",
        "resourceUUID",
        "secretReferenceSHA256",
        "signerPublicKeySHA256",
        "verification"
    ]

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

    static func redactedJSONPreservingInvalid(
        _ json: String,
        using policy: RuntimeRedactionPolicy = .default
    ) -> String {
        (try? redactedJSON(json, using: policy)) ?? policy.redact(json)
    }

    static func redactedEventPayload(
        _ json: String,
        type: String,
        source: String,
        using policy: RuntimeRedactionPolicy = .default
    ) -> String {
        if type == HostwrightTraceContract.eventType,
           source == HostwrightTraceContract.source,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(
               HostwrightTraceSpanRecord.self,
               from: data
           ),
           let validated = try? decoded.validated() {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .sortedKeys,
                .withoutEscapingSlashes
            ]
            if let encoded = try? encoder.encode(validated) {
                return String(decoding: encoded, as: UTF8.self)
            }
        }
        return redactedJSONPreservingInvalid(json, using: policy)
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
                if nonSecretStructuredKeys.contains(key) {
                    redacted[key] = redact(nested, key: nil, using: policy)
                } else if nonSecretIdentityKeys.contains(key), let string = nested as? String {
                    redacted[key] = string
                } else {
                    redacted[key] = policy.isSensitiveKey(key)
                        ? policy.replacement
                        : redact(nested, key: key, using: policy)
                }
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map { redact($0, key: nil, using: policy) }
        }
        if let string = value as? String {
            return policy.redact(string)
        }
        return value
    }

    private static func redact(_ value: Any, key: String?, using policy: RuntimeRedactionPolicy) -> Any {
        if let key, nonSecretIdentityKeys.contains(key), let string = value as? String {
            return string
        }
        return redact(value, using: policy)
    }
}
