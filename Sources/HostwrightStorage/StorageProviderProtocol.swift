import Foundation

public protocol StorageProviderSPI: Sendable {
    func descriptor() async throws -> StorageProviderDescriptor
    func invoke(canonicalRequest: Data) async throws -> Data
    func cancel(requestID: UUID) async
}

public enum StorageProviderProtocolError: Error, Equatable, Sendable {
    case emptyRequest
    case requestTooLarge(maximumBytes: Int)
    case emptyResult
    case resultTooLarge(maximumBytes: Int)
    case invalidJSON
    case nonCanonicalJSON
    case unsupportedProtocolVersion(Int)
    case invalidRequestID
    case invalidCapabilityDigest
    case capabilityDigestMismatch
    case invalidDeadline
    case expiredDeadline
    case deadlineTooFar
    case invalidIdempotencyKey
    case mutationContextRequired
    case invalidMutationContext
    case staleResourceGeneration(expected: Int, actual: Int)
    case staleAttachmentGeneration(expected: Int, actual: Int?)
    case duplicateRequestID
    case replayWindowExhausted
    case cancelled
    case providerHung
    case invalidResultEnvelope
    case responseMismatch
}

public enum StorageProviderCanonicalJSON {
    public static func encodeRequest<Payload>(
        _ request: StorageProviderRequest<Payload>
    ) throws -> Data {
        let data = try encode(request)
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyRequest
        }
        guard data.count <= StorageProviderContract.maximumRequestBytes else {
            throw StorageProviderProtocolError.requestTooLarge(
                maximumBytes: StorageProviderContract.maximumRequestBytes
            )
        }
        return data
    }

    public static func decodeRequest<Payload>(
        _ payloadType: Payload.Type,
        from data: Data
    ) throws -> StorageProviderRequest<Payload> {
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyRequest
        }
        guard data.count <= StorageProviderContract.maximumRequestBytes else {
            throw StorageProviderProtocolError.requestTooLarge(
                maximumBytes: StorageProviderContract.maximumRequestBytes
            )
        }
        let request: StorageProviderRequest<Payload> = try decodeCanonical(from: data)
        guard request.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                request.protocolVersion
            )
        }
        return request
    }

    public static func encodeResult<ResultPayload>(
        _ result: StorageProviderResultEnvelope<ResultPayload>
    ) throws -> Data {
        let data = try encode(result)
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyResult
        }
        guard data.count <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderProtocolError.resultTooLarge(
                maximumBytes: StorageProviderContract.maximumResultBytes
            )
        }
        return data
    }

    public static func decodeResult<ResultPayload>(
        _ resultType: ResultPayload.Type,
        from data: Data
    ) throws -> StorageProviderResultEnvelope<ResultPayload> {
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyResult
        }
        guard data.count <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderProtocolError.resultTooLarge(
                maximumBytes: StorageProviderContract.maximumResultBytes
            )
        }
        let result: StorageProviderResultEnvelope<ResultPayload> = try decodeCanonical(from: data)
        guard result.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                result.protocolVersion
            )
        }
        return result
    }

    public static func encodeError(_ error: StorageProviderErrorEnvelope) throws -> Data {
        let data = try encode(error)
        guard data.count <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderProtocolError.resultTooLarge(
                maximumBytes: StorageProviderContract.maximumResultBytes
            )
        }
        return data
    }

    public static func decodeError(from data: Data) throws -> StorageProviderErrorEnvelope {
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyResult
        }
        guard data.count <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderProtocolError.resultTooLarge(
                maximumBytes: StorageProviderContract.maximumResultBytes
            )
        }
        let error: StorageProviderErrorEnvelope = try decodeCanonical(from: data)
        guard error.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                error.protocolVersion
            )
        }
        return error
    }

    public static func encodeDescriptor(_ descriptor: StorageProviderDescriptor) throws -> Data {
        try StorageProviderDescriptorValidator.validate(descriptor)
        return try encode(descriptor)
    }

    public static func decodeDescriptor(from data: Data) throws -> StorageProviderDescriptor {
        guard !data.isEmpty else {
            throw StorageProviderProtocolError.emptyResult
        }
        guard data.count <= StorageProviderContract.maximumResultBytes else {
            throw StorageProviderProtocolError.resultTooLarge(
                maximumBytes: StorageProviderContract.maximumResultBytes
            )
        }
        let descriptor: StorageProviderDescriptor = try decodeCanonical(from: data)
        try StorageProviderDescriptorValidator.validate(descriptor)
        return descriptor
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decodeCanonical<Value: Codable>(from data: Data) throws -> Value {
        let decoded: Value
        do {
            decoded = try JSONDecoder().decode(Value.self, from: data)
        } catch let error as StorageProviderProtocolError {
            throw error
        } catch {
            throw StorageProviderProtocolError.invalidJSON
        }

        let canonical = try encode(decoded)
        guard canonical == data else {
            throw StorageProviderProtocolError.nonCanonicalJSON
        }
        return decoded
    }
}

public struct StorageProviderRequestValidator: Sendable {
    private let expectedCapabilitySHA256: String
    private var seenRequestIDs: Set<UUID>

    public init(expectedCapabilitySHA256: String) {
        self.expectedCapabilitySHA256 = expectedCapabilitySHA256
        seenRequestIDs = []
    }

    public mutating func validate<Payload>(
        _ request: StorageProviderRequest<Payload>,
        nowUnixMilliseconds: Int64,
        expectedResourceGeneration: Int? = nil,
        expectedAttachmentGeneration: Int? = nil,
        cancellationRequested: Bool = false
    ) throws {
        try validate(
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            operation: request.operation,
            deadlineUnixMilliseconds: request.deadlineUnixMilliseconds,
            capabilitySHA256: request.capabilitySHA256,
            idempotencyKey: request.idempotencyKey,
            mutationContext: request.mutationContext,
            nowUnixMilliseconds: nowUnixMilliseconds,
            expectedResourceGeneration: expectedResourceGeneration,
            expectedAttachmentGeneration: expectedAttachmentGeneration,
            cancellationRequested: cancellationRequested
        )
    }

    public mutating func validate(
        protocolVersion: Int,
        requestID: UUID,
        operation: StorageProviderOperation,
        deadlineUnixMilliseconds: Int64,
        capabilitySHA256: String,
        idempotencyKey: String,
        mutationContext: StorageProviderMutationContext?,
        nowUnixMilliseconds: Int64,
        expectedResourceGeneration: Int? = nil,
        expectedAttachmentGeneration: Int? = nil,
        cancellationRequested: Bool = false
    ) throws {
        guard protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                protocolVersion
            )
        }
        guard Self.validSHA256(capabilitySHA256) else {
            throw StorageProviderProtocolError.invalidCapabilityDigest
        }
        guard capabilitySHA256 == expectedCapabilitySHA256 else {
            throw StorageProviderProtocolError.capabilityDigestMismatch
        }
        guard deadlineUnixMilliseconds > 0 else {
            throw StorageProviderProtocolError.invalidDeadline
        }
        guard deadlineUnixMilliseconds > nowUnixMilliseconds else {
            throw StorageProviderProtocolError.expiredDeadline
        }
        let deadlineWindow = deadlineUnixMilliseconds
            .subtractingReportingOverflow(nowUnixMilliseconds)
        guard !deadlineWindow.overflow,
              deadlineWindow.partialValue <=
                StorageProviderContract.maximumDeadlineWindowMilliseconds else {
            throw StorageProviderProtocolError.deadlineTooFar
        }
        guard Self.validIdempotencyKey(idempotencyKey) else {
            throw StorageProviderProtocolError.invalidIdempotencyKey
        }
        guard !cancellationRequested else {
            throw StorageProviderProtocolError.cancelled
        }

        if operation.mutatesProviderState {
            guard let context = mutationContext else {
                throw StorageProviderProtocolError.mutationContextRequired
            }
            guard context.isValid else {
                throw StorageProviderProtocolError.invalidMutationContext
            }
            if let expectedResourceGeneration,
               context.resourceGeneration != expectedResourceGeneration {
                throw StorageProviderProtocolError.staleResourceGeneration(
                    expected: expectedResourceGeneration,
                    actual: context.resourceGeneration
                )
            }
            if let expectedAttachmentGeneration,
               context.attachmentGeneration != expectedAttachmentGeneration {
                throw StorageProviderProtocolError.staleAttachmentGeneration(
                    expected: expectedAttachmentGeneration,
                    actual: context.attachmentGeneration
                )
            }
        }

        guard !seenRequestIDs.contains(requestID) else {
            throw StorageProviderProtocolError.duplicateRequestID
        }
        guard seenRequestIDs.count < StorageProviderContract.maximumRememberedRequestIDs else {
            throw StorageProviderProtocolError.replayWindowExhausted
        }
        seenRequestIDs.insert(requestID)
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validIdempotencyKey(_ value: String) -> Bool {
        value.utf8.count >= 1 &&
            value.utf8.count <= 256 &&
            value.unicodeScalars.allSatisfy {
                $0.isASCII && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

public enum StorageProviderResponseValidator {
    public static func validate<ResultPayload>(
        _ result: StorageProviderResultEnvelope<ResultPayload>,
        for requestID: UUID,
        operation: StorageProviderOperation
    ) throws {
        guard result.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                result.protocolVersion
            )
        }
        guard result.requestID == requestID, result.operation == operation else {
            throw StorageProviderProtocolError.responseMismatch
        }
    }

    public static func validate(
        _ error: StorageProviderErrorEnvelope,
        for requestID: UUID,
        operation: StorageProviderOperation
    ) throws {
        guard error.protocolVersion == StorageProviderContract.protocolVersion else {
            throw StorageProviderProtocolError.unsupportedProtocolVersion(
                error.protocolVersion
            )
        }
        guard error.requestID == requestID, error.operation == operation else {
            throw StorageProviderProtocolError.responseMismatch
        }
    }
}

public enum StorageProviderTransportTermination: Equatable, Sendable {
    case timedOut
    case cancelled
    case hung
    case crashed
    case outputOverflow
    case unavailable
    case permissionDenied
    case ambiguousEffect
}

public enum StorageProviderFailureNormalizer {
    public static func normalize(
        _ termination: StorageProviderTransportTermination,
        operation: StorageProviderOperation
    ) -> StorageProviderFailure {
        let observedMutation = operation.mutatesProviderState
        switch termination {
        case .timedOut, .hung:
            return StorageProviderFailure(
                category: .timedOut,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: observedMutation ? .reobserve : .none,
                diagnostic: "The storage provider did not complete before the bounded deadline.",
                guidance: observedMutation
                    ? "Re-observe the exact volume generation before deciding whether to retry."
                    : "Retry only after provider health is restored."
            )
        case .cancelled:
            return StorageProviderFailure(
                category: .cancelled,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: observedMutation ? .reobserve : .none,
                diagnostic: "The storage provider operation was cancelled.",
                guidance: observedMutation
                    ? "Re-observe the exact volume generation before deciding whether to resume."
                    : "The read-only operation may be retried."
            )
        case .crashed:
            return StorageProviderFailure(
                category: .crashed,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: observedMutation ? .reobserve : .none,
                diagnostic: "The storage provider exited before returning a verified result.",
                guidance: "Restore provider health and re-observe before retrying."
            )
        case .outputOverflow:
            return StorageProviderFailure(
                category: .outputLimited,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: observedMutation ? .reobserve : .none,
                diagnostic: "The storage provider exceeded the bounded result size.",
                guidance: "Treat provider state as unknown until structured observation succeeds."
            )
        case .unavailable:
            return StorageProviderFailure(
                category: .unavailable,
                retryDisposition: .safeAfterObservation,
                recoveryDisposition: .none,
                diagnostic: "The storage provider is unavailable.",
                guidance: "Restore the selected provider and negotiate capabilities again."
            )
        case .permissionDenied:
            return StorageProviderFailure(
                category: .permissionDenied,
                retryDisposition: .never,
                recoveryDisposition: .none,
                diagnostic: "The storage provider denied the operation.",
                guidance: "Restore the required local permission without weakening the trust boundary."
            )
        case .ambiguousEffect:
            return StorageProviderFailure(
                category: .ambiguousEffect,
                retryDisposition: .resumeFromCheckpoint,
                recoveryDisposition: .safeHold,
                diagnostic: "The provider effect cannot be proven from the returned evidence.",
                guidance: "Hold mutation and recover from durable intent after exact re-observation."
            )
        }
    }

    public static func normalize(
        _ error: StorageProviderProtocolError
    ) -> StorageProviderFailure {
        let category: StorageProviderFailureCategory
        let retry: StorageProviderRetryDisposition
        let recovery: StorageProviderRecoveryDisposition

        switch error {
        case .unsupportedProtocolVersion:
            category = .incompatible
            retry = .never
            recovery = .none
        case .staleResourceGeneration, .staleAttachmentGeneration:
            category = .staleGeneration
            retry = .safeAfterObservation
            recovery = .reobserve
        case .duplicateRequestID, .replayWindowExhausted:
            category = .replayedRequest
            retry = .never
            recovery = .safeHold
        case .cancelled:
            category = .cancelled
            retry = .safeAfterObservation
            recovery = .reobserve
        case .providerHung, .expiredDeadline:
            category = .timedOut
            retry = .safeAfterObservation
            recovery = .reobserve
        case .requestTooLarge, .resultTooLarge:
            category = .outputLimited
            retry = .never
            recovery = .none
        case .capabilityDigestMismatch:
            category = .incompatible
            retry = .never
            recovery = .reobserve
        default:
            category = .invalidRequest
            retry = .never
            recovery = .none
        }

        return StorageProviderFailure(
            category: category,
            retryDisposition: retry,
            recoveryDisposition: recovery,
            diagnostic: "Storage Provider API v1 rejected the request as \(String(describing: error)).",
            guidance: guidance(for: category)
        )
    }

    private static func guidance(for category: StorageProviderFailureCategory) -> String {
        switch category {
        case .incompatible:
            "Negotiate a compatible provider and generate a fresh operation plan."
        case .staleGeneration:
            "Re-observe the exact resource generation before generating a new request."
        case .replayedRequest:
            "Stop the session and recover from durable idempotency evidence."
        case .cancelled, .timedOut, .crashed, .ambiguousEffect:
            "Re-observe the exact owned resource before deciding whether to retry."
        case .outputLimited:
            "Treat provider state as unknown until bounded structured observation succeeds."
        default:
            "Correct the rejected request before attempting it again."
        }
    }
}
