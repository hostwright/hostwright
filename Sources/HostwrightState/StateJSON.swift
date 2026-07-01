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

    static func redactedJSON(_ json: String, using policy: RuntimeRedactionPolicy = .default) -> String {
        policy.redact(json)
    }
}
