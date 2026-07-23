import Foundation
import HostwrightRuntime

func waitForAsync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()

    Task.detached {
        do {
            box.result = Result.success(try await operation())
        } catch {
            box.result = Result.failure(error)
        }
        semaphore.signal()
    }

    semaphore.wait()
    return try box.result!.get()
}

final class AsyncResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

func stableHash(_ value: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return String(format: "%016llx", hash)
}

func jsonPayload(_ object: [String: Any]) -> String {
    let redacted = redactJSONValue(object)
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

private let hostwrightNonSecretJSONIdentityKeys: Set<String> = [
    "capabilitySHA256",
    "checkpoint",
    "confirmationToken",
    "fencingToken",
    "operationID",
    "planHash",
    "projectResourceUUID",
    "projectUUID",
    "resourceFencingToken",
    "resourceUUID",
    "verification"
]

func redactJSONValue(_ value: Any, key: String? = nil) -> Any {
    switch value {
    case let dictionary as [String: Any]:
        var result: [String: Any] = [:]
        result.reserveCapacity(dictionary.count)
        for (nestedKey, nestedValue) in dictionary {
            if hostwrightNonSecretJSONIdentityKeys.contains(nestedKey),
               let string = nestedValue as? String {
                result[nestedKey] = string
            } else {
                result[nestedKey] = redactJSONValue(nestedValue, key: nestedKey)
            }
        }
        return result
    case let array as [Any]:
        return array.map { redactJSONValue($0, key: key) }
    case let string as String:
        if let key, hostwrightNonSecretJSONIdentityKeys.contains(key) {
            return string
        }
        return RuntimeRedactionPolicy.default.redact(string)
    default:
        return value
    }
}
