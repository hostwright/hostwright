import CryptoKit
import Foundation
import HostwrightAccelerator

package final class AcceleratorStateXPCReplayStore:
    AcceleratorXPCDurableReplayStore,
    @unchecked Sendable
{
    private static let fence = try! AcceleratorStateRepositoryFence(
        nodeEpoch: 1,
        reservationSequence: 1
    )

    private let repository: AcceleratorStateRepository

    package init(store: SQLiteStateStore) {
        self.repository = AcceleratorStateRepository(store: store)
    }

    package func begin(
        _ identity: AcceleratorXPCDurableReplayIdentity,
        observedAt: Date
    ) throws -> AcceleratorXPCDurableReplayDisposition {
        let recordID = identity.requestID.uuidString.lowercased()
        guard let current = try repository.current(
            AcceleratorXPCReplayStateRecord.self,
            kind: .xpcReplay,
            recordID: recordID
        ) else {
            let payload = try AcceleratorXPCReplayStatePayload(
                requestID: identity.requestID,
                operation: identity.operation,
                protocolVersion: identity.protocolVersion,
                idempotencyDigest: identity.idempotencyDigest,
                state: .pending
            )
            let record = try AcceleratorXPCReplayStateRecord(
                recordID: identity.requestID,
                sequence: 1,
                previousRecordDigest: nil,
                payload: payload
            )
            do {
                _ = try repository.append(
                    record,
                    fence: Self.fence,
                    observedAt: observedAt,
                    mutationID: Self.mutationID(recordID: recordID, sequence: 1)
                )
            } catch let error as AcceleratorStateRepositoryError {
                throw Self.map(error)
            }
            return .admitted
        }

        guard current.payload.requestID == identity.requestID,
              current.payload.operation == identity.operation,
              current.payload.protocolVersion == identity.protocolVersion,
              current.payload.idempotencyDigest == identity.idempotencyDigest else {
            throw AcceleratorXPCDurableReplayStoreError.idempotencyConflict
        }
        switch current.payload.state {
        case .pending:
            return .inFlight
        case .completed:
            guard let response = current.payload.responseJSON else {
                throw AcceleratorXPCDurableReplayStoreError.invalidPersistedRecord
            }
            return .replayed(response)
        }
    }

    package func complete(
        _ identity: AcceleratorXPCDurableReplayIdentity,
        response: Data,
        observedAt: Date
    ) throws {
        let recordID = identity.requestID.uuidString.lowercased()
        guard response.count <= AcceleratorStateRepository.maximumPayloadBytes else {
            throw AcceleratorXPCDurableReplayStoreError.responseTooLarge
        }
        let responseDigest = try AcceleratorDigest(
            SHA256.hash(data: response)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        guard let current = try repository.current(
            AcceleratorXPCReplayStateRecord.self,
            kind: .xpcReplay,
            recordID: recordID
        ) else {
            throw AcceleratorXPCDurableReplayStoreError.invalidPersistedRecord
        }
        guard current.payload.requestID == identity.requestID,
              current.payload.operation == identity.operation,
              current.payload.protocolVersion == identity.protocolVersion,
              current.payload.idempotencyDigest == identity.idempotencyDigest else {
            throw AcceleratorXPCDurableReplayStoreError.idempotencyConflict
        }
        switch current.payload.state {
        case .completed:
            guard current.payload.responseJSON == response,
                  current.payload.responseSHA256 == responseDigest else {
                throw AcceleratorXPCDurableReplayStoreError.idempotencyConflict
            }
            return
        case .pending:
            break
        }
        let payload = try AcceleratorXPCReplayStatePayload(
            requestID: identity.requestID,
            operation: identity.operation,
            protocolVersion: identity.protocolVersion,
            idempotencyDigest: identity.idempotencyDigest,
            state: .completed,
            responseJSON: response,
            responseSHA256: responseDigest
        )
        let sequence = current.sequence + 1
        let record = try AcceleratorXPCReplayStateRecord(
            recordID: identity.requestID,
            sequence: sequence,
            previousRecordDigest: current.recordDigest,
            payload: payload
        )
        do {
            _ = try repository.append(
                record,
                fence: Self.fence,
                observedAt: observedAt,
                mutationID: Self.mutationID(recordID: recordID, sequence: sequence),
                expected: try AcceleratorStateRepositoryExpectedVersion(
                    generation: current.sequence,
                    fence: Self.fence
                )
            )
        } catch let error as AcceleratorStateRepositoryError {
            throw Self.map(error)
        }
    }

    private static func mutationID(recordID: String, sequence: Int64) -> String {
        "xpc-replay:\(recordID):\(sequence)"
    }

    private static func map(
        _ error: AcceleratorStateRepositoryError
    ) -> AcceleratorXPCDurableReplayStoreError {
        switch error {
        case .idempotencyConflict, .expectedVersionMismatch, .generationConflict,
             .fenceConflict, .duplicateRecordID:
            return .idempotencyConflict
        case .malformedPersistedRecord:
            return .invalidPersistedRecord
        default:
            return .storageUnavailable
        }
    }
}
