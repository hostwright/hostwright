import Foundation

public struct StorageProviderInvocationFailure:
    Error,
    Equatable,
    Sendable
{
    public let operation: StorageProviderOperation
    public let failure: StorageProviderFailure

    public init(
        operation: StorageProviderOperation,
        failure: StorageProviderFailure
    ) {
        self.operation = operation
        self.failure = failure
    }
}

public struct StorageProviderClient: Sendable {
    public let provider: any StorageProviderSPI
    public let requestTimeoutMilliseconds: Int64

    private let nowUnixMilliseconds: @Sendable () -> Int64
    private let requestID: @Sendable () -> UUID

    public init(
        provider: any StorageProviderSPI,
        requestTimeoutMilliseconds: Int64 = 30_000,
        nowUnixMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        },
        requestID: @escaping @Sendable () -> UUID = { UUID() }
    ) throws {
        guard (1...StorageProviderContract
            .maximumDeadlineWindowMilliseconds)
            .contains(requestTimeoutMilliseconds) else {
            throw StorageProviderProtocolError.invalidDeadline
        }
        self.provider = provider
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.requestID = requestID
    }

    public func descriptor() async throws -> StorageProviderDescriptor {
        let descriptor = try await provider.descriptor()
        try StorageProviderDescriptorValidator.validate(descriptor)
        return descriptor
    }

    public func invoke<
        Payload: Codable & Sendable,
        ResultPayload: Codable & Sendable
    >(
        operation: StorageProviderOperation,
        mutationContext: StorageProviderMutationContext? = nil,
        idempotencyKey: String,
        payload: Payload,
        result: ResultPayload.Type
    ) async throws -> ResultPayload {
        let descriptor = try await descriptor()
        try StorageProviderCapabilityNegotiator.requireAvailable(
            operation,
            in: descriptor
        )
        let now = nowUnixMilliseconds()
        let (deadline, overflow) = now.addingReportingOverflow(
            requestTimeoutMilliseconds
        )
        guard !overflow else {
            throw StorageProviderProtocolError.invalidDeadline
        }
        let request = StorageProviderRequest(
            requestID: requestID(),
            operation: operation,
            deadlineUnixMilliseconds: deadline,
            capabilitySHA256: try descriptor.canonicalSHA256(),
            idempotencyKey: idempotencyKey,
            mutationContext: mutationContext,
            payload: payload
        )
        let response = try await provider.invoke(
            canonicalRequest:
                StorageProviderCanonicalJSON.encodeRequest(request)
        )
        if let envelope = try? StorageProviderCanonicalJSON.decodeResult(
            ResultPayload.self,
            from: response
        ) {
            try StorageProviderResponseValidator.validate(
                envelope,
                for: request.requestID,
                operation: operation
            )
            return envelope.result
        }
        let failure = try StorageProviderCanonicalJSON.decodeError(
            from: response
        )
        try StorageProviderResponseValidator.validate(
            failure,
            for: request.requestID,
            operation: operation
        )
        throw StorageProviderInvocationFailure(
            operation: operation,
            failure: failure.failure
        )
    }
}
