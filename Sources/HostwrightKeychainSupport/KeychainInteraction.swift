import Foundation
import Security

package enum KeychainInteraction {
    package struct Failure: Error {
        package let status: OSStatus
    }

    private static let lock = NSRecursiveLock()

    package static func withDisabled<Value>(
        _ operation: () -> Value
    ) -> Result<Value, Failure> {
        // File-based Keychains can ignore LAContext. This flag affects the whole process.
        lock.lock()
        defer { lock.unlock() }

        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { return .failure(Failure(status: readStatus)) }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { return .failure(Failure(status: disableStatus)) }

        let result = operation()
        let restoreStatus = SecKeychainSetUserInteractionAllowed(previous.boolValue)
        guard restoreStatus == errSecSuccess else { return .failure(Failure(status: restoreStatus)) }
        return .success(result)
    }
}
