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
    let redacted = object.mapValues { value -> Any in
        if let string = value as? String {
            return RuntimeRedactionPolicy.default.redact(string)
        }
        return value
    }
    let data = try! JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}
