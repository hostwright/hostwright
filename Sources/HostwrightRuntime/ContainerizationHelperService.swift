import Foundation
import HostwrightCore

public struct ContainerizationHelperEmptyPayload: Codable, Equatable, Sendable {
    public init() {}
}

public struct ContainerizationHelperObservePayload: Codable, Equatable, Sendable {
    public let includeResourceUsage: Bool

    public init(includeResourceUsage: Bool = true) {
        self.includeResourceUsage = includeResourceUsage
    }
}

public struct ContainerizationHelperObservation: Codable, Equatable, Sendable {
    public let machine: RuntimeInventoryMachine
    public let containers: [RuntimeInventoryContainer]
    public let images: [RuntimeInventoryImage]
    public let networks: [RuntimeInventoryNetwork]
    public let volumes: [RuntimeInventoryVolume]
    public let semanticSHA256: String

    public init(inventory: RuntimeInventory) {
        self.machine = inventory.machine
        self.containers = inventory.containers
        self.images = inventory.images
        self.networks = inventory.networks
        self.volumes = inventory.volumes
        self.semanticSHA256 = inventory.semanticSHA256
    }

    public func validatedInventory() throws -> RuntimeInventory {
        let inventory = try RuntimeInventoryBuilder.build(
            machine: machine,
            containers: containers,
            images: images,
            networks: networks,
            volumes: volumes
        )
        guard inventory.semanticSHA256 == semanticSHA256 else {
            throw ContainerizationHelperServiceError.invalidPayload
        }
        return inventory
    }
}

public struct ContainerizationHelperImageRequest: Codable, Equatable, Sendable {
    public let reference: String

    public init(reference: String) {
        self.reference = reference
    }
}

public struct ContainerizationHelperImageEvidence: Codable, Equatable, Sendable {
    public let reference: String
    public let descriptorDigest: String
    public let variantDigest: String
    public let architecture: String
    public let operatingSystem: String

    public init(
        reference: String,
        descriptorDigest: String,
        variantDigest: String,
        architecture: String,
        operatingSystem: String
    ) {
        self.reference = reference
        self.descriptorDigest = descriptorDigest
        self.variantDigest = variantDigest
        self.architecture = architecture
        self.operatingSystem = operatingSystem
    }

    public init(_ evidence: RuntimeLocalImageEvidence) {
        self.init(
            reference: evidence.reference,
            descriptorDigest: evidence.descriptorDigest,
            variantDigest: evidence.variantDigest,
            architecture: evidence.architecture,
            operatingSystem: evidence.operatingSystem
        )
    }
}

public struct ContainerizationHelperResourceRequest: Codable, Equatable, Sendable {
    public let resourceIdentifier: String

    public init(resourceIdentifier: String) {
        self.resourceIdentifier = resourceIdentifier
    }
}

public struct ContainerizationHelperResourceUsage: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let cpuUsageMicroseconds: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkTransmitBytes: UInt64
    public let blockReadBytes: UInt64
    public let blockWriteBytes: UInt64
    public let processCount: Int

    public init(_ usage: RuntimeResourceUsageSnapshot) {
        self.resourceIdentifier = usage.resourceIdentifier
        self.cpuUsageMicroseconds = usage.cpuUsageMicroseconds
        self.memoryUsageBytes = usage.memoryUsageBytes
        self.memoryLimitBytes = usage.memoryLimitBytes
        self.networkReceiveBytes = usage.networkReceiveBytes
        self.networkTransmitBytes = usage.networkTransmitBytes
        self.blockReadBytes = usage.blockReadBytes
        self.blockWriteBytes = usage.blockWriteBytes
        self.processCount = usage.processCount
    }

    public init(
        resourceIdentifier: String,
        cpuUsageMicroseconds: UInt64,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkTransmitBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        processCount: Int
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
    }
}

public struct ContainerizationHelperLogsRequest: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let lineLimit: Int

    public init(resourceIdentifier: String, lineLimit: Int) {
        self.resourceIdentifier = resourceIdentifier
        self.lineLimit = lineLimit
    }
}

public struct ContainerizationHelperLogs: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let text: String
    public let lineLimit: Int

    public init(resourceIdentifier: String, text: String, lineLimit: Int) {
        self.resourceIdentifier = resourceIdentifier
        self.text = RuntimeRedactionPolicy.default.redact(text)
        self.lineLimit = lineLimit
    }
}

public struct ContainerizationHelperCreatePayload: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let resourceUUID: String
    public let projectUUID: String
    public let image: ContainerizationHelperImageEvidence
    public let command: [String]
    public let environment: [RuntimeInventoryEnvironmentEntry]
    public let labels: [RuntimeInventoryLabel]

    public init(
        resourceIdentifier: String,
        resourceUUID: String,
        projectUUID: String,
        image: ContainerizationHelperImageEvidence,
        command: [String],
        environment: [RuntimeInventoryEnvironmentEntry],
        labels: [RuntimeInventoryLabel]
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.resourceUUID = resourceUUID
        self.projectUUID = projectUUID
        self.image = image
        self.command = command
        self.environment = environment
        self.labels = labels
    }
}

public struct ContainerizationHelperMutationPayload: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let resourceUUID: String

    public init(resourceIdentifier: String, resourceUUID: String) {
        self.resourceIdentifier = resourceIdentifier
        self.resourceUUID = resourceUUID
    }
}

public struct ContainerizationHelperMutationResult: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let lifecycle: RuntimeInventoryLifecycleState
    public let verified: Bool

    public init(
        resourceIdentifier: String,
        lifecycle: RuntimeInventoryLifecycleState,
        verified: Bool
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.lifecycle = lifecycle
        self.verified = verified
    }
}

public struct ContainerizationHelperCancellationPayload: Codable, Equatable, Sendable {
    public let targetRequestID: UUID

    public init(targetRequestID: UUID) {
        self.targetRequestID = targetRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case targetRequestID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = try values.decode(String.self, forKey: .targetRequestID)
        guard let value = UUID(uuidString: text), value.uuidString.lowercased() == text else {
            throw ContainerizationHelperProtocolError.invalidRequestID
        }
        targetRequestID = value
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(targetRequestID.uuidString.lowercased(), forKey: .targetRequestID)
    }
}

public struct ContainerizationHelperAcknowledgement: Codable, Equatable, Sendable {
    public let accepted: Bool

    public init(accepted: Bool) {
        self.accepted = accepted
    }
}

public enum ContainerizationHelperBackendError: Error, Equatable, Sendable {
    case unavailable(String)
    case rejected(String)
    case conflict(String)
    case executionFailed(String)
}

public protocol ContainerizationHelperBackend: Sendable {
    func negotiate() async throws -> RuntimeCapabilitySnapshot
    func observe(_ request: ContainerizationHelperObservePayload) async throws -> ContainerizationHelperObservation
    func localImageEvidence(_ request: ContainerizationHelperImageRequest) async throws -> ContainerizationHelperImageEvidence
    func resourceUsage(_ request: ContainerizationHelperResourceRequest) async throws -> ContainerizationHelperResourceUsage
    func logs(_ request: ContainerizationHelperLogsRequest) async throws -> ContainerizationHelperLogs
    func create(
        _ request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult
    func start(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult
    func stop(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult
    func restart(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult
    func delete(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult
    func cancel(requestID: UUID) async
    func shutdown() async
}

public enum ContainerizationHelperServiceError: Error, Equatable, Sendable {
    case invalidPayload
    case operationMismatch
    case mutationContextRequired
    case mutationIdentityMismatch
    case imageNotLocal
    case invalidLineLimit
    case invalidText
    case shuttingDown
}

public actor ContainerizationHelperDispatcher {
    private struct RoutingEnvelope: Decodable {
        let operation: ContainerizationHelperOperation
    }

    private let backend: any ContainerizationHelperBackend
    private var requestValidator: ContainerizationHelperRequestValidator
    private var negotiationValidator = ContainerizationHelperRequestValidator()
    private var acceptedRequestIDs: Set<UUID> = []
    private var activeCancellations: [UUID: @Sendable () -> Void] = [:]
    private var shutdownRequested = false

    public init(
        backend: any ContainerizationHelperBackend,
        expectedCapabilityDigest: String
    ) {
        self.backend = backend
        self.requestValidator = ContainerizationHelperRequestValidator(
            expectedCapabilityDigest: expectedCapabilityDigest
        )
    }

    public func dispatch(frame: Data, nowUnixMilliseconds: Int64) async throws -> Data {
        let payload = try ContainerizationHelperFraming.decodeSingleFrame(frame)
        let operation: ContainerizationHelperOperation
        do {
            operation = try JSONDecoder().decode(RoutingEnvelope.self, from: payload).operation
        } catch {
            throw ContainerizationHelperProtocolError.invalidJSON
        }

        switch operation {
        case .negotiate:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperEmptyPayload.self,
                allowsCapabilityRenegotiation: true,
                validate: { request in
                    try Self.requireReadOnly(request)
                },
                action: { [backend] _ in try await backend.negotiate() }
            )
        case .observe:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperObservePayload.self,
                validate: { request in
                    try Self.requireReadOnly(request)
                },
                action: { [backend] request in try await backend.observe(request.payload) }
            )
        case .localImageEvidence:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperImageRequest.self,
                validate: { request in
                    try Self.requireReadOnly(request)
                    try Self.requireText(request.payload.reference)
                },
                action: { [backend] request in try await backend.localImageEvidence(request.payload) }
            )
        case .resourceUsage:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperResourceRequest.self,
                validate: { request in
                    try Self.requireReadOnly(request)
                    try Self.requireText(request.payload.resourceIdentifier)
                },
                action: { [backend] request in try await backend.resourceUsage(request.payload) }
            )
        case .logs:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperLogsRequest.self,
                validate: { request in
                    try Self.requireReadOnly(request)
                    try Self.requireText(request.payload.resourceIdentifier)
                    guard (1...10_000).contains(request.payload.lineLimit) else {
                        throw ContainerizationHelperServiceError.invalidLineLimit
                    }
                },
                action: { [backend] request in try await backend.logs(request.payload) }
            )
        case .create:
            return try await execute(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                payloadType: ContainerizationHelperCreatePayload.self,
                validate: { request in
                    let context = try Self.requireMutation(request, resourceUUID: request.payload.resourceUUID)
                    guard context.projectResourceUUID == request.payload.projectUUID else {
                        throw ContainerizationHelperServiceError.mutationIdentityMismatch
                    }
                    try Self.validateCreate(request.payload)
                },
                action: { [backend] request in
                    let context = try Self.requireMutation(request, resourceUUID: request.payload.resourceUUID)
                    let evidence = try await backend.localImageEvidence(
                        ContainerizationHelperImageRequest(reference: request.payload.image.reference)
                    )
                    guard evidence == request.payload.image else {
                        throw ContainerizationHelperServiceError.imageNotLocal
                    }
                    let result = try await backend.create(request.payload, context: context)
                    return try Self.requireVerifiedResult(
                        result,
                        resourceIdentifier: request.payload.resourceIdentifier,
                        lifecycle: .created
                    )
                }
            )
        case .start:
            return try await mutation(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                action: { [backend] request, context in
                    try Self.requireVerifiedResult(
                        try await backend.start(request, context: context),
                        resourceIdentifier: request.resourceIdentifier,
                        lifecycle: .running
                    )
                }
            )
        case .stop:
            return try await mutation(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                action: { [backend] request, context in
                    try Self.requireVerifiedResult(
                        try await backend.stop(request, context: context),
                        resourceIdentifier: request.resourceIdentifier,
                        lifecycle: .stopped
                    )
                }
            )
        case .restart:
            return try await mutation(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                action: { [backend] request, context in
                    try Self.requireVerifiedResult(
                        try await backend.restart(request, context: context),
                        resourceIdentifier: request.resourceIdentifier,
                        lifecycle: .running
                    )
                }
            )
        case .delete:
            return try await mutation(
                payload: payload,
                operation: operation,
                nowUnixMilliseconds: nowUnixMilliseconds,
                action: { [backend] request, context in
                    try Self.requireVerifiedResult(
                        try await backend.delete(request, context: context),
                        resourceIdentifier: request.resourceIdentifier,
                        lifecycle: .missing
                    )
                }
            )
        case .cancel:
            return try await cancel(payload: payload, nowUnixMilliseconds: nowUnixMilliseconds)
        case .shutdown:
            return try await shutdown(payload: payload, nowUnixMilliseconds: nowUnixMilliseconds)
        }
    }

    public func shouldTerminate() -> Bool {
        shutdownRequested
    }

    public func requestShutdown() async {
        guard !shutdownRequested else { return }
        shutdownRequested = true
        for cancel in activeCancellations.values {
            cancel()
        }
        await backend.shutdown()
    }

    private func mutation(
        payload: Data,
        operation: ContainerizationHelperOperation,
        nowUnixMilliseconds: Int64,
        action: @escaping @Sendable (
            ContainerizationHelperMutationPayload,
            RuntimeMutationContext
        ) async throws -> ContainerizationHelperMutationResult
    ) async throws -> Data {
        try await execute(
            payload: payload,
            operation: operation,
            nowUnixMilliseconds: nowUnixMilliseconds,
            payloadType: ContainerizationHelperMutationPayload.self,
            validate: { request in
                _ = try Self.requireMutation(request, resourceUUID: request.payload.resourceUUID)
                try Self.requireText(request.payload.resourceIdentifier)
            },
            action: { request in
                let context = try Self.requireMutation(request, resourceUUID: request.payload.resourceUUID)
                return try await action(request.payload, context)
            }
        )
    }

    private func cancel(payload: Data, nowUnixMilliseconds: Int64) async throws -> Data {
        let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
            ContainerizationHelperCancellationPayload.self,
            from: payload
        )
        guard request.operation == .cancel else {
            throw ContainerizationHelperServiceError.operationMismatch
        }
        do {
            try validateRequest(request, nowUnixMilliseconds: nowUnixMilliseconds)
            guard request.mutationContext == nil,
                  request.payload.targetRequestID != request.requestID else {
                throw ContainerizationHelperServiceError.invalidPayload
            }
            let cancellation = activeCancellations[request.payload.targetRequestID]
            cancellation?()
            await backend.cancel(requestID: request.payload.targetRequestID)
            return try Self.resultFrame(
                request: request,
                result: ContainerizationHelperAcknowledgement(accepted: cancellation != nil)
            )
        } catch {
            return try Self.errorFrame(request: request, error: error)
        }
    }

    private func shutdown(payload: Data, nowUnixMilliseconds: Int64) async throws -> Data {
        let request = try ContainerizationHelperCanonicalJSON.decodeRequest(
            ContainerizationHelperEmptyPayload.self,
            from: payload
        )
        guard request.operation == .shutdown else {
            throw ContainerizationHelperServiceError.operationMismatch
        }
        do {
            try validateRequest(request, nowUnixMilliseconds: nowUnixMilliseconds)
            try Self.requireReadOnly(request)
            await requestShutdown()
            return try Self.resultFrame(
                request: request,
                result: ContainerizationHelperAcknowledgement(accepted: true)
            )
        } catch {
            return try Self.errorFrame(request: request, error: error)
        }
    }

    private func execute<Payload: Codable & Sendable, Result: Codable & Sendable>(
        payload: Data,
        operation: ContainerizationHelperOperation,
        nowUnixMilliseconds: Int64,
        payloadType: Payload.Type,
        allowsCapabilityRenegotiation: Bool = false,
        validate: (ContainerizationHelperRequest<Payload>) throws -> Void,
        action: @escaping @Sendable (ContainerizationHelperRequest<Payload>) async throws -> Result
    ) async throws -> Data {
        let request = try ContainerizationHelperCanonicalJSON.decodeRequest(payloadType, from: payload)
        guard request.operation == operation else {
            throw ContainerizationHelperServiceError.operationMismatch
        }
        do {
            guard !shutdownRequested else {
                throw ContainerizationHelperServiceError.shuttingDown
            }
            try validateRequest(
                request,
                nowUnixMilliseconds: nowUnixMilliseconds,
                allowsCapabilityRenegotiation: allowsCapabilityRenegotiation
            )
            try validate(request)

            let task = Task<Result, Error> {
                try Task.checkCancellation()
                return try await action(request)
            }
            activeCancellations[request.requestID] = { task.cancel() }
            defer { activeCancellations.removeValue(forKey: request.requestID) }

            let result = try await task.value
            return try Self.resultFrame(request: request, result: result)
        } catch {
            return try Self.errorFrame(request: request, error: error)
        }
    }

    private static func requireReadOnly<Payload>(_ request: ContainerizationHelperRequest<Payload>) throws {
        guard request.mutationContext == nil else {
            throw ContainerizationHelperServiceError.invalidPayload
        }
    }

    private func validateRequest<Payload: Codable & Sendable>(
        _ request: ContainerizationHelperRequest<Payload>,
        nowUnixMilliseconds: Int64,
        allowsCapabilityRenegotiation: Bool = false
    ) throws {
        if allowsCapabilityRenegotiation {
            try negotiationValidator.validate(request, nowUnixMilliseconds: nowUnixMilliseconds)
        } else {
            try requestValidator.validate(request, nowUnixMilliseconds: nowUnixMilliseconds)
        }
        guard acceptedRequestIDs.insert(request.requestID).inserted else {
            throw ContainerizationHelperProtocolError.duplicateRequestID
        }
    }

    private static func requireMutation<Payload>(
        _ request: ContainerizationHelperRequest<Payload>,
        resourceUUID: String
    ) throws -> RuntimeMutationContext {
        guard let context = request.mutationContext else {
            throw ContainerizationHelperServiceError.mutationContextRequired
        }
        guard context.resourceUUID == resourceUUID,
              context.providerID == .appleContainerization,
              context.capabilitySHA256 == request.capabilityDigest else {
            throw ContainerizationHelperServiceError.mutationIdentityMismatch
        }
        return context
    }

    private static func validateCreate(_ payload: ContainerizationHelperCreatePayload) throws {
        try requireText(payload.resourceIdentifier)
        try requireText(payload.image.reference)
        guard HostwrightResourceUUID.isValid(payload.resourceUUID),
              HostwrightResourceUUID.isValid(payload.projectUUID),
              payload.command.count <= RuntimeInventoryLimits.maximumArgumentsPerContainer,
              payload.environment.count <= RuntimeInventoryLimits.maximumEnvironmentEntriesPerContainer,
              payload.labels.count <= RuntimeInventoryLimits.maximumLabelsPerResource else {
            throw ContainerizationHelperServiceError.invalidPayload
        }
        for item in payload.command {
            try requireText(item)
        }
        for entry in payload.environment {
            try requireText(entry.name)
            try requireText(entry.value)
        }
        for label in payload.labels {
            try requireText(label.key)
            try requireText(label.value)
        }
    }

    private static func requireVerifiedResult(
        _ result: ContainerizationHelperMutationResult,
        resourceIdentifier: String,
        lifecycle: RuntimeInventoryLifecycleState
    ) throws -> ContainerizationHelperMutationResult {
        guard result.resourceIdentifier == resourceIdentifier,
              result.lifecycle == lifecycle,
              result.verified else {
            throw ContainerizationHelperServiceError.invalidPayload
        }
        return result
    }

    private static func requireText(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= RuntimeInventoryLimits.maximumStringBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ContainerizationHelperServiceError.invalidText
        }
    }

    private static func resultFrame<Payload: Codable & Sendable, Result: Codable & Sendable>(
        request: ContainerizationHelperRequest<Payload>,
        result: Result
    ) throws -> Data {
        let envelope = ContainerizationHelperResultEnvelope(
            requestID: request.requestID,
            operation: request.operation,
            result: result
        )
        return try ContainerizationHelperFraming.frame(
            ContainerizationHelperCanonicalJSON.encode(envelope)
        )
    }

    private static func errorFrame<Payload: Codable & Sendable>(
        request: ContainerizationHelperRequest<Payload>,
        error: Error
    ) throws -> Data {
        let payload: ContainerizationHelperErrorPayload
        switch error {
        case is CancellationError:
            payload = .init(code: .cancelled, message: "The helper operation was cancelled.")
        case ContainerizationHelperProtocolError.expiredDeadline:
            payload = .init(code: .deadlineExceeded, message: "The helper request deadline expired.")
        case ContainerizationHelperProtocolError.capabilityDigestMismatch:
            payload = .init(code: .capabilityMismatch, message: "The helper capability snapshot is stale.")
        case let backendError as ContainerizationHelperBackendError:
            switch backendError {
            case .unavailable:
                payload = .init(code: .unavailable, message: "The requested helper capability is unavailable.")
            case .rejected:
                payload = .init(code: .executionFailed, message: "The helper rejected the requested operation.")
            case .conflict:
                payload = .init(code: .conflict, message: "The helper detected a conflicting operation.")
            case .executionFailed:
                payload = .init(code: .executionFailed, message: "The helper operation failed.")
            }
        case ContainerizationHelperServiceError.shuttingDown:
            payload = .init(code: .unavailable, message: "The helper is shutting down.")
        case is ContainerizationHelperProtocolError,
             is ContainerizationHelperServiceError:
            payload = .init(code: .invalidRequest, message: "The helper request is invalid.")
        default:
            payload = .init(code: .internalFailure, message: "The helper could not complete the operation.")
        }
        let envelope = ContainerizationHelperErrorEnvelope(
            requestID: request.requestID,
            operation: request.operation,
            error: payload
        )
        return try ContainerizationHelperFraming.frame(
            ContainerizationHelperCanonicalJSON.encode(envelope)
        )
    }
}
