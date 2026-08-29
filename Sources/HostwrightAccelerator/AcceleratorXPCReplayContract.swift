import Foundation

package enum AcceleratorXPCReplayLifecycleState: String, Codable, Equatable, Hashable, Sendable {
    case pending
    case completed
}

package struct AcceleratorXPCDurableReplayIdentity: Codable, Equatable, Hashable, Sendable {
    package let requestID: UUID
    package let operation: String
    package let protocolVersion: Int
    package let idempotencyDigest: AcceleratorDigest

    package init(
        requestID: UUID,
        operation: String,
        protocolVersion: Int,
        idempotencyDigest: AcceleratorDigest
    ) throws {
        let zero = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        guard requestID != zero else {
            throw AcceleratorXPCDurableReplayStoreError.invalidIdentity
        }
        guard protocolVersion == 1 else {
            throw AcceleratorXPCDurableReplayStoreError.invalidIdentity
        }
        guard (1...32).contains(operation.utf8.count),
              operation.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...90, 97...122, 45:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw AcceleratorXPCDurableReplayStoreError.invalidIdentity
        }
        self.requestID = requestID
        self.operation = operation
        self.protocolVersion = protocolVersion
        self.idempotencyDigest = idempotencyDigest
    }
}

package enum AcceleratorXPCDurableReplayDisposition: Sendable {
    case admitted
    case replayed(Data)
    case inFlight
}

package enum AcceleratorXPCDurableReplayStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case idempotencyConflict
    case invalidPersistedRecord
    case responseTooLarge
    case storageUnavailable
}

package protocol AcceleratorXPCDurableReplayStore: Sendable {
    func begin(
        _ identity: AcceleratorXPCDurableReplayIdentity,
        observedAt: Date
    ) throws -> AcceleratorXPCDurableReplayDisposition

    func complete(
        _ identity: AcceleratorXPCDurableReplayIdentity,
        response: Data,
        observedAt: Date
    ) throws
}
