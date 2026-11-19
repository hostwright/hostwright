import Dispatch
import Security
import XCTest
@testable import HostwrightCluster
@testable import HostwrightSecrets

final class KeychainInteractionTests: XCTestCase {
    private enum OperationError: Error, Equatable {
        case expected
    }

    func testSecretAndClusterCallsSerializeAndRestoreOriginalFlag() {
        var original = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)

        let secretEntered = DispatchSemaphore(value: 0)
        let releaseSecret = DispatchSemaphore(value: 0)
        let clusterAttempted = DispatchSemaphore(value: 0)
        let clusterEntered = DispatchSemaphore(value: 0)
        let workers = DispatchGroup()

        DispatchQueue(label: "keychain-secret").async(group: workers) {
            let status = MacOSKeychainSecretStore.noninteractive {
                Self.assertInteractionDisabled()
                secretEntered.signal()
                XCTAssertEqual(releaseSecret.wait(timeout: .now() + 5), .success)
                Self.assertInteractionDisabled()
                return errSecSuccess
            }
            XCTAssertEqual(status, errSecSuccess)
        }

        XCTAssertEqual(secretEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue(label: "keychain-cluster").async(group: workers) {
            clusterAttempted.signal()
            do {
                try ClusterCertificateKeychainStore.withUserInteractionDisabled { () throws -> Void in
                    Self.assertInteractionDisabled()
                    clusterEntered.signal()
                    throw OperationError.expected
                }
                XCTFail("The cluster operation error should be rethrown.")
            } catch {
                XCTAssertEqual(error as? OperationError, .expected)
            }
        }

        XCTAssertEqual(clusterAttempted.wait(timeout: .now() + 5), .success)
        let clusterEnteredEarly = clusterEntered.wait(timeout: .now() + .milliseconds(100)) == .success
        XCTAssertFalse(clusterEnteredEarly, "The cluster call entered before the secret call restored the flag.")
        releaseSecret.signal()
        if !clusterEnteredEarly {
            XCTAssertEqual(clusterEntered.wait(timeout: .now() + 5), .success)
        }
        XCTAssertEqual(workers.wait(timeout: .now() + 5), .success)

        var restored = DarwinBoolean(false)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(restored.boolValue, original.boolValue)
    }

    private static func assertInteractionDisabled() {
        var value = DarwinBoolean(true)
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&value), errSecSuccess)
        XCTAssertFalse(value.boolValue)
    }
}
