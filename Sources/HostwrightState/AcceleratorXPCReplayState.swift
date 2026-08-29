import CryptoKit
import Foundation
import HostwrightAccelerator

package struct AcceleratorXPCReplayStatePayload:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    package let requestID: UUID
    package let operation: String
    package let protocolVersion: Int
    package let idempotencyDigest: AcceleratorDigest
    package let state: AcceleratorXPCReplayLifecycleState
    package let responseJSON: Data?
    package let responseSHA256: AcceleratorDigest?

    package init(
        requestID: UUID,
        operation: String,
        protocolVersion: Int,
        idempotencyDigest: AcceleratorDigest,
        state: AcceleratorXPCReplayLifecycleState,
        responseJSON: Data? = nil,
        responseSHA256: AcceleratorDigest? = nil
    ) throws {
        try Self.validateIdentity(
            requestID: requestID,
            operation: operation,
            protocolVersion: protocolVersion,
            idempotencyDigest: idempotencyDigest
        )
        switch state {
        case .pending:
            guard responseJSON == nil, responseSHA256 == nil else {
                throw AcceleratorStateRecordValidationError(
                    code: .invalidState,
                    field: "response"
                )
            }
        case .completed:
            guard let responseJSON, let responseSHA256 else {
                throw AcceleratorStateRecordValidationError(
                    code: .invalidState,
                    field: "response"
                )
            }
            try Self.validateResponse(responseJSON, digest: responseSHA256)
        }
        self.requestID = requestID
        self.operation = operation
        self.protocolVersion = protocolVersion
        self.idempotencyDigest = idempotencyDigest
        self.state = state
        self.responseJSON = responseJSON
        self.responseSHA256 = responseSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case operation
        case protocolVersion
        case idempotencyDigest
        case state
        case responseJSON
        case responseSHA256
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(operation, forKey: .operation)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(idempotencyDigest, forKey: .idempotencyDigest)
        try container.encode(state, forKey: .state)
        if let responseJSON {
            try container.encode(responseJSON, forKey: .responseJSON)
        } else {
            try container.encodeNil(forKey: .responseJSON)
        }
        if let responseSHA256 {
            try container.encode(responseSHA256, forKey: .responseSHA256)
        } else {
            try container.encodeNil(forKey: .responseSHA256)
        }
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue)) == [
            "requestID", "operation", "protocolVersion", "idempotencyDigest",
            "state", "responseJSON", "responseSHA256"
        ] else {
            throw AcceleratorStateRecordValidationError(
                code: .unknownField,
                field: "replay"
            )
        }
        try self.init(
            requestID: container.decode(UUID.self, forKey: .requestID),
            operation: container.decode(String.self, forKey: .operation),
            protocolVersion: container.decode(Int.self, forKey: .protocolVersion),
            idempotencyDigest: container.decode(AcceleratorDigest.self, forKey: .idempotencyDigest),
            state: container.decode(AcceleratorXPCReplayLifecycleState.self, forKey: .state),
            responseJSON: container.decodeIfPresent(Data.self, forKey: .responseJSON),
            responseSHA256: container.decodeIfPresent(AcceleratorDigest.self, forKey: .responseSHA256)
        )
    }

    private static func validateIdentity(
        requestID: UUID,
        operation: String,
        protocolVersion: Int,
        idempotencyDigest: AcceleratorDigest
    ) throws {
        let zero = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        )
        guard requestID != zero else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidIdentifier,
                field: "requestID"
            )
        }
        guard ["inventory", "status", "execute", "cancel", "revoke"].contains(operation) else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidBinding,
                field: "operation"
            )
        }
        guard protocolVersion == 1 else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidVersion,
                field: "protocolVersion"
            )
        }
        guard idempotencyDigest.value.count == 64 else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidDigest,
                field: "idempotencyDigest"
            )
        }
    }

    private static func validateResponse(
        _ data: Data,
        digest: AcceleratorDigest
    ) throws {
        guard (1...AcceleratorStateRepository.maximumPayloadBytes).contains(data.count) else {
            throw AcceleratorStateRecordValidationError(
                code: .oversizedRecord,
                field: "responseJSON"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidState,
                field: "responseJSON"
            )
        }
        let expected = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest.value == expected else {
            throw AcceleratorStateRecordValidationError(
                code: .invalidDigest,
                field: "responseSHA256"
            )
        }
    }
}

extension AcceleratorXPCReplayStatePayload: AcceleratorStatePayload {
    package static var statePayloadKey: String { "xpcReplay" }
    package static var statePayloadKeys: Set<String>? {
        [
            "requestID", "operation", "protocolVersion", "idempotencyDigest",
            "state", "responseJSON", "responseSHA256"
        ]
    }
}

package typealias AcceleratorXPCReplayStateRecord =
    AcceleratorStateRecord<AcceleratorXPCReplayStatePayload>
