import Darwin
import Dispatch
import Foundation
import HostwrightAccelerator
@preconcurrency import XPC

public struct AcceleratorXPCModelArtifact: Codable, Equatable, Sendable {
    public let modelHash: AcceleratorDigest
    public let bytes: Data

    public init(modelHash: AcceleratorDigest, bytes: Data) throws {
        guard (1...AcceleratorXPCContract.maxModelBytes).contains(bytes.count) else {
            throw AcceleratorXPCValidationError(code: .payloadTooLarge, field: "modelArtifact.bytes")
        }
        guard try AcceleratorXPCDigest.sha256(bytes) == modelHash else {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "modelArtifact.modelHash")
        }
        self.modelHash = modelHash
        self.bytes = bytes
    }

    private enum CodingKeys: String, CodingKey {
        case modelHash
        case bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set(["modelHash", "bytes"]) else {
            throw AcceleratorXPCValidationError(code: .unknownField, field: "modelArtifact")
        }
        try self.init(
            modelHash: container.decode(AcceleratorDigest.self, forKey: .modelHash),
            bytes: container.decode(Data.self, forKey: .bytes)
        )
    }
}

public struct AcceleratorXPCBackendExecutionContext: Sendable {
    public let payload: AcceleratorXPCExecutePayload
    public let modelArtifact: AcceleratorXPCModelArtifact

    public init(
        payload: AcceleratorXPCExecutePayload,
        modelArtifact: AcceleratorXPCModelArtifact
    ) throws {
        guard modelArtifact.modelHash == payload.request.modelHash else {
            throw AcceleratorXPCValidationError(code: .requestMismatch, field: "modelHash")
        }
        self.payload = payload
        self.modelArtifact = modelArtifact
    }
}

public enum AcceleratorXPCBackendError: Error, Equatable, Sendable {
    case unavailable
    case unsupported
}

public protocol AcceleratorXPCBackend: Sendable {
    func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot

    func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot

    func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact

    func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult
}

public enum AcceleratorXPCRequestRegistryError: Error, Equatable, Sendable {
    case idempotencyConflict
    case concurrencyLimitExceeded
    case budgetLimitExceeded
    case replayHistoryExhausted
    case replayHistoryUnavailable
    case cancellationHistoryExhausted
    case revocationHistoryExhausted
}

public struct AcceleratorXPCRegistryLimits: Codable, Equatable, Sendable {
    public let maxCompletedResponses: Int
    public let maxRequestHistory: Int
    public let maxCancellationRecords: Int
    public let maxRevocationKeys: Int

    public init(
        maxCompletedResponses: Int = 1_024,
        maxRequestHistory: Int = 4_096,
        maxCancellationRecords: Int = 4_096,
        maxRevocationKeys: Int = 4_096
    ) throws {
        guard (1...1_000_000).contains(maxCompletedResponses),
              (1...1_000_000).contains(maxRequestHistory),
              (1...1_000_000).contains(maxCancellationRecords),
              (1...1_000_000).contains(maxRevocationKeys) else {
            throw AcceleratorXPCValidationError(code: .invalidPayload, field: "registryLimits")
        }
        self.maxCompletedResponses = maxCompletedResponses
        self.maxRequestHistory = maxRequestHistory
        self.maxCancellationRecords = maxCancellationRecords
        self.maxRevocationKeys = maxRevocationKeys
    }

    private enum CodingKeys: String, CodingKey {
        case maxCompletedResponses
        case maxRequestHistory
        case maxCancellationRecords
        case maxRevocationKeys
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(container.allKeys.map(\.stringValue)) == Set([
            "maxCompletedResponses", "maxRequestHistory", "maxCancellationRecords", "maxRevocationKeys"
        ]) else {
            throw AcceleratorXPCValidationError(code: .unknownField, field: "registryLimits")
        }
        try self.init(
            maxCompletedResponses: container.decode(Int.self, forKey: .maxCompletedResponses),
            maxRequestHistory: container.decode(Int.self, forKey: .maxRequestHistory),
            maxCancellationRecords: container.decode(Int.self, forKey: .maxCancellationRecords),
            maxRevocationKeys: container.decode(Int.self, forKey: .maxRevocationKeys)
        )
    }
}

public enum AcceleratorXPCRequestAdmission: Equatable, Sendable {
    case admitted
    case replayed(AcceleratorXPCResponse)
}

public final class AcceleratorXPCRequestRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let maxConcurrent: Int
    public let limits: AcceleratorXPCRegistryLimits
    private var activeByDigest: [AcceleratorDigest: UUID] = [:]
    private var activeOperationByDigest: [AcceleratorDigest: AcceleratorXPCOperation] = [:]
    private struct ActiveExecution {
        let binding: AcceleratorXPCExecutionBinding
        let cancellation: @Sendable () -> Void
    }
    private struct RevocationBinding: Hashable {
        let targetKind: String
        let targetIdentifier: String
        let scope: AcceleratorScope?
        let fence: AcceleratorFence?
        let actor: AcceleratorAuthenticationContext
        let claim: AcceleratorClaim?
        let grant: AcceleratorGrant?
        let reservation: AcceleratorReservation?

        init(_ payload: AcceleratorXPCRevokePayload) {
            self.targetKind = payload.revocation.targetKind.rawValue
            self.targetIdentifier = payload.revocation.targetIdentifier
            self.scope = payload.revocation.scope
            self.fence = payload.revocation.fence
            self.actor = payload.revocation.actor
            self.claim = payload.claim
            self.grant = payload.grant
            self.reservation = payload.reservation
        }

        func matches(binding: AcceleratorXPCExecutionBinding) -> Bool {
            switch targetKind {
            case AcceleratorRevocationTargetKind.claim.rawValue:
                binding.claim == claim
                    && binding.claim.scope == scope
                    && binding.claim.claimID.uuidString.lowercased() == targetIdentifier
            case AcceleratorRevocationTargetKind.grant.rawValue:
                binding.grant == grant
                    && (claim == nil || binding.claim == claim)
                    && binding.grant.scope == scope
                    && binding.grant.fence == fence
                    && binding.grant.grantID.uuidString.lowercased() == targetIdentifier
            case AcceleratorRevocationTargetKind.reservation.rawValue:
                binding.reservation == reservation
                    && (claim == nil || binding.claim == claim)
                    && (grant == nil || binding.grant == grant)
                    && binding.reservation.scope == scope
                    && binding.reservation.fence == fence
                    && binding.reservation.reservationID.uuidString.lowercased() == targetIdentifier
            case AcceleratorRevocationTargetKind.session.rawValue:
                binding.request.authentication == actor
                    && binding.request.authentication.sessionID == targetIdentifier
            default:
                false
            }
        }
    }
    private var activeExecutions: [AcceleratorXPCExecutionBinding: ActiveExecution] = [:]
    private enum BudgetAuthorityKey: Hashable {
        case claim(scope: AcceleratorScope, id: UUID)
        case grant(scope: AcceleratorScope, id: UUID)
        case reservation(scope: AcceleratorScope, id: UUID)
        case inventory(snapshotID: UUID, generation: Int64, mode: AcceleratorExecutionMode)
    }
    private struct BudgetCharge: Equatable {
        let memoryBytes: UInt64
        let computeUnits: UInt64
        let concurrencyUnits: UInt64

        static let zero = BudgetCharge(
            memoryBytes: 0,
            computeUnits: 0,
            concurrencyUnits: 0
        )

        func adding(_ other: BudgetCharge) throws -> BudgetCharge {
            let memory = memoryBytes.addingReportingOverflow(other.memoryBytes)
            let compute = computeUnits.addingReportingOverflow(other.computeUnits)
            let concurrency = concurrencyUnits.addingReportingOverflow(other.concurrencyUnits)
            guard !memory.overflow, !compute.overflow, !concurrency.overflow else {
                throw AcceleratorXPCRequestRegistryError.budgetLimitExceeded
            }
            return BudgetCharge(
                memoryBytes: memory.partialValue,
                computeUnits: compute.partialValue,
                concurrencyUnits: concurrency.partialValue
            )
        }

        func subtracting(_ other: BudgetCharge) -> BudgetCharge {
            BudgetCharge(
                memoryBytes: memoryBytes - other.memoryBytes,
                computeUnits: computeUnits - other.computeUnits,
                concurrencyUnits: concurrencyUnits - other.concurrencyUnits
            )
        }
    }
    private struct ExecutionCharge {
        let entries: [(key: BudgetAuthorityKey, requested: BudgetCharge, limit: BudgetCharge)]
    }
    private var activeBudgetByKey: [BudgetAuthorityKey: BudgetCharge] = [:]
    private var budgetReservationByDigest: [
        AcceleratorDigest: [(key: BudgetAuthorityKey, charge: BudgetCharge)]
    ] = [:]
    private var requestDigestByID: [UUID: AcceleratorDigest] = [:]
    private var knownDigests: Set<AcceleratorDigest> = []
    private var completedByDigest: [AcceleratorDigest: AcceleratorXPCResponse] = [:]
    private var completedOrder: [AcceleratorDigest] = []
    private var cancelledBindings: Set<AcceleratorXPCExecutionBinding> = []
    private var cancellationBindingByID: [UUID: AcceleratorXPCExecutionBinding] = [:]
    private var cancellationOrder: [UUID] = []
    private var revokedBindings: Set<RevocationBinding> = []
    private var revocationOrder: [RevocationBinding] = []
    private var retainedExecutionDigests: Set<AcceleratorDigest> = []
    private var terminatedExecutionDigests: Set<AcceleratorDigest> = []
    private var heldResponseByDigest: [AcceleratorDigest: AcceleratorXPCResponse] = [:]

    private var activeCountUnsafe: Int {
        activeOperationByDigest.values.filter { $0 == .execute }.count
    }

    public init(
        maxConcurrent: Int = AcceleratorLimits.maxConcurrency,
        limits: AcceleratorXPCRegistryLimits? = nil
    ) throws {
        guard (1...AcceleratorLimits.maxConcurrency).contains(maxConcurrent) else {
            throw AcceleratorXPCValidationError(
                code: .concurrencyLimitExceeded,
                field: "maxConcurrent"
            )
        }
        self.maxConcurrent = maxConcurrent
        self.limits = try limits ?? AcceleratorXPCRegistryLimits()
    }

    public var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeOperationByDigest.values.filter { $0 == .execute }.count
    }

    public func begin(
        _ request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCRequestAdmission {
        lock.lock()
        defer { lock.unlock() }

        let executionCharge = try Self.executionCharge(for: request)

        if let priorDigest = requestDigestByID[request.requestID], priorDigest != request.idempotencyDigest {
            throw AcceleratorXPCRequestRegistryError.idempotencyConflict
        }
        let isNewRequest = requestDigestByID[request.requestID] == nil
        if isNewRequest {
            if request.operation == .execute {
                guard activeCountUnsafe < maxConcurrent else {
                    throw AcceleratorXPCRequestRegistryError.concurrencyLimitExceeded
                }
            }
            guard requestDigestByID.count < limits.maxRequestHistory else {
                throw AcceleratorXPCRequestRegistryError.replayHistoryExhausted
            }
            guard !knownDigests.contains(request.idempotencyDigest) else {
                throw AcceleratorXPCRequestRegistryError.idempotencyConflict
            }
            if let executionCharge {
                try reserve(executionCharge)
            }
            knownDigests.insert(request.idempotencyDigest)
            requestDigestByID[request.requestID] = request.idempotencyDigest
        }

        if let completed = completedByDigest[request.idempotencyDigest] {
            guard completed.requestID == request.requestID,
                  completed.operation == request.operation else {
                throw AcceleratorXPCRequestRegistryError.idempotencyConflict
            }
            return .replayed(try Self.replayed(completed))
        }
        if !isNewRequest,
           knownDigests.contains(request.idempotencyDigest),
           activeByDigest[request.idempotencyDigest] == nil,
           requestDigestByID[request.requestID] != nil {
            throw AcceleratorXPCRequestRegistryError.replayHistoryUnavailable
        }
        if let activeRequestID = activeByDigest[request.idempotencyDigest] {
            guard activeRequestID == request.requestID else {
                throw AcceleratorXPCRequestRegistryError.idempotencyConflict
            }
            throw AcceleratorXPCRequestRegistryError.idempotencyConflict
        }
        if request.operation == .execute {
            guard activeCountUnsafe < maxConcurrent else {
                throw AcceleratorXPCRequestRegistryError.concurrencyLimitExceeded
            }
        }
        activeByDigest[request.idempotencyDigest] = request.requestID
        activeOperationByDigest[request.idempotencyDigest] = request.operation
        if let executionCharge, isNewRequest {
            budgetReservationByDigest[request.idempotencyDigest] = executionCharge.entries.map {
                (key: $0.key, charge: $0.requested)
            }
        }
        return .admitted
    }

    @discardableResult
    public func finish(
        _ request: AcceleratorXPCRequest,
        response: AcceleratorXPCResponse
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if retainedExecutionDigests.contains(request.idempotencyDigest) {
            heldResponseByDigest[request.idempotencyDigest] = response
            return terminatedExecutionDigests.contains(request.idempotencyDigest)
        }
        storeCompleted(response, for: request.idempotencyDigest)
        return true
    }

    private func storeCompleted(
        _ response: AcceleratorXPCResponse,
        for digest: AcceleratorDigest
    ) {
        activeByDigest.removeValue(forKey: digest)
        activeOperationByDigest.removeValue(forKey: digest)
        releaseBudget(for: digest)
        completedByDigest.removeValue(forKey: digest)
        completedOrder.removeAll { $0 == digest }
        if completedByDigest.count >= limits.maxCompletedResponses,
           let oldest = completedOrder.first {
            completedOrder.removeFirst()
            completedByDigest.removeValue(forKey: oldest)
        }
        completedByDigest[digest] = response
        completedOrder.append(digest)
    }

    func executionIsRetained(_ request: AcceleratorXPCRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return retainedExecutionDigests.contains(request.idempotencyDigest)
    }

    func markExecutionTerminated(
        binding: AcceleratorXPCExecutionBinding
    ) -> AcceleratorXPCResponse? {
        lock.lock()
        defer { lock.unlock() }
        activeExecutions.removeValue(forKey: binding)
        guard let digest = activeByDigest.first(where: { $0.value == binding.request.requestID })?.key,
              retainedExecutionDigests.contains(digest) else {
            return nil
        }
        terminatedExecutionDigests.insert(digest)
        return heldResponseByDigest[digest]
    }

    func releaseHeldExecution(_ request: AcceleratorXPCRequest) {
        lock.lock()
        defer { lock.unlock() }
        let digest = request.idempotencyDigest
        guard retainedExecutionDigests.contains(digest),
              terminatedExecutionDigests.contains(digest),
              let response = heldResponseByDigest[digest] else {
            return
        }
        heldResponseByDigest.removeValue(forKey: digest)
        retainedExecutionDigests.remove(digest)
        terminatedExecutionDigests.remove(digest)
        storeCompleted(response, for: digest)
    }

    func retainExecutionUntilTermination(_ request: AcceleratorXPCRequest) {
        lock.lock()
        defer { lock.unlock() }
        retainedExecutionDigests.insert(request.idempotencyDigest)
    }

    func unregisterExecution(binding: AcceleratorXPCExecutionBinding) {
        lock.lock()
        defer { lock.unlock() }
        activeExecutions.removeValue(forKey: binding)
    }

    public func abandon(_ request: AcceleratorXPCRequest) {
        lock.lock()
        defer { lock.unlock() }
        activeByDigest.removeValue(forKey: request.idempotencyDigest)
        activeOperationByDigest.removeValue(forKey: request.idempotencyDigest)
        releaseBudget(for: request.idempotencyDigest)
    }

    func cancel(
        binding: AcceleratorXPCExecutionBinding,
        cancellationID: UUID
    ) throws {
        lock.lock()
        if let priorBinding = cancellationBindingByID[cancellationID] {
            guard priorBinding == binding else {
                lock.unlock()
                throw AcceleratorXPCRequestRegistryError.idempotencyConflict
            }
        } else {
            guard cancellationBindingByID.count < limits.maxCancellationRecords else {
                lock.unlock()
                throw AcceleratorXPCRequestRegistryError.cancellationHistoryExhausted
            }
            cancellationBindingByID[cancellationID] = binding
            cancelledBindings.insert(binding)
            cancellationOrder.append(cancellationID)
        }
        let cancellation = activeExecutions[binding]?.cancellation
        lock.unlock()
        cancellation?()
    }

    func revoke(payload: AcceleratorXPCRevokePayload) throws {
        lock.lock()
        let binding = RevocationBinding(payload)
        if !revokedBindings.contains(binding) {
            guard revokedBindings.count < limits.maxRevocationKeys else {
                lock.unlock()
                throw AcceleratorXPCRequestRegistryError.revocationHistoryExhausted
            }
            revokedBindings.insert(binding)
            revocationOrder.append(binding)
        }
        let cancellations = activeExecutions.values.compactMap { active -> (@Sendable () -> Void)? in
            binding.matches(binding: active.binding) ? active.cancellation : nil
        }
        lock.unlock()
        cancellations.forEach { $0() }
    }

    func registerExecution(
        binding: AcceleratorXPCExecutionBinding,
        cancellation: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        activeExecutions[binding] = ActiveExecution(
            binding: binding,
            cancellation: cancellation
        )
        let alreadyCancelled = cancelledBindings.contains(binding)
        let alreadyRevoked = revokedBindings.contains { $0.matches(binding: binding) }
        lock.unlock()
        if alreadyCancelled || alreadyRevoked {
            cancellation()
        }
    }

    func isCancelled(binding: AcceleratorXPCExecutionBinding) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledBindings.contains(binding)
    }

    public func isRevoked(_ payload: AcceleratorXPCExecutePayload) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revokedBindings.contains { revoked in
            revoked.matches(binding: AcceleratorXPCExecutionBinding(
                request: payload.request,
                claim: payload.claim,
                grant: payload.grant,
                reservation: payload.reservation,
                inventory: payload.inventory
            ))
        }
    }

    private static func executionCharge(
        for request: AcceleratorXPCRequest
    ) throws -> ExecutionCharge? {
        guard case .execute(let payload) = request.payload else {
            return nil
        }
        let requested = BudgetCharge(
            memoryBytes: payload.request.budget.memoryBytes,
            computeUnits: payload.request.budget.computeUnits,
            concurrencyUnits: payload.request.budget.concurrencyUnits
        )
        let claimLimit = BudgetCharge(
            memoryBytes: payload.claim.quota.budget.memoryBytes,
            computeUnits: payload.claim.quota.budget.computeUnits,
            concurrencyUnits: payload.claim.quota.budget.concurrencyUnits
        )
        let grantLimit = BudgetCharge(
            memoryBytes: payload.grant.quota.budget.memoryBytes,
            computeUnits: payload.grant.quota.budget.computeUnits,
            concurrencyUnits: payload.grant.quota.budget.concurrencyUnits
        )
        let reservationLimit = BudgetCharge(
            memoryBytes: payload.reservation.budget.memoryBytes,
            computeUnits: payload.reservation.budget.computeUnits,
            concurrencyUnits: payload.reservation.budget.concurrencyUnits
        )
        var limits = BudgetCharge(
            memoryBytes: min(claimLimit.memoryBytes, grantLimit.memoryBytes, reservationLimit.memoryBytes),
            computeUnits: min(claimLimit.computeUnits, grantLimit.computeUnits, reservationLimit.computeUnits),
            concurrencyUnits: min(claimLimit.concurrencyUnits, grantLimit.concurrencyUnits, reservationLimit.concurrencyUnits)
        )
        var measuredLimits = BudgetCharge(
            memoryBytes: UInt64.max,
            computeUnits: UInt64.max,
            concurrencyUnits: UInt64.max
        )
        let measured: [(AcceleratorBudgetKind, UInt64)] = [
            (.memory, limits.memoryBytes),
            (.compute, limits.computeUnits),
            (.concurrency, limits.concurrencyUnits)
        ]
        for (kind, currentLimit) in measured {
            guard let budget = payload.inventory.budget(
                for: payload.request.mode,
                kind: kind
            ), budget.observedGeneration == payload.inventory.observedGeneration else {
                throw AcceleratorXPCRequestRegistryError.budgetLimitExceeded
            }
            let bounded = min(currentLimit, budget.amount)
            let measuredBounded: UInt64 = switch kind {
            case .memory: min(measuredLimits.memoryBytes, budget.amount)
            case .compute: min(measuredLimits.computeUnits, budget.amount)
            case .concurrency: min(measuredLimits.concurrencyUnits, budget.amount)
            }
            switch kind {
            case .memory:
                limits = BudgetCharge(
                    memoryBytes: bounded,
                    computeUnits: limits.computeUnits,
                    concurrencyUnits: limits.concurrencyUnits
                )
            case .compute:
                limits = BudgetCharge(
                    memoryBytes: limits.memoryBytes,
                    computeUnits: bounded,
                    concurrencyUnits: limits.concurrencyUnits
                )
            case .concurrency:
                limits = BudgetCharge(
                    memoryBytes: limits.memoryBytes,
                    computeUnits: limits.computeUnits,
                    concurrencyUnits: bounded
                )
            }
            switch kind {
            case .memory:
                measuredLimits = BudgetCharge(
                    memoryBytes: measuredBounded,
                    computeUnits: measuredLimits.computeUnits,
                    concurrencyUnits: measuredLimits.concurrencyUnits
                )
            case .compute:
                measuredLimits = BudgetCharge(
                    memoryBytes: measuredLimits.memoryBytes,
                    computeUnits: measuredBounded,
                    concurrencyUnits: measuredLimits.concurrencyUnits
                )
            case .concurrency:
                measuredLimits = BudgetCharge(
                    memoryBytes: measuredLimits.memoryBytes,
                    computeUnits: measuredLimits.computeUnits,
                    concurrencyUnits: measuredBounded
                )
            }
        }
        guard requested.memoryBytes <= limits.memoryBytes,
              requested.computeUnits <= limits.computeUnits,
              requested.concurrencyUnits <= limits.concurrencyUnits else {
            throw AcceleratorXPCRequestRegistryError.budgetLimitExceeded
        }
        return ExecutionCharge(
            entries: [
                (
                    .claim(scope: payload.claim.scope, id: payload.claim.claimID),
                    requested,
                    claimLimit
                ),
                (
                    .grant(scope: payload.grant.scope, id: payload.grant.grantID),
                    requested,
                    grantLimit
                ),
                (
                    .reservation(scope: payload.reservation.scope, id: payload.reservation.reservationID),
                    requested,
                    reservationLimit
                ),
                (
                    .inventory(
                        snapshotID: payload.inventory.snapshotID,
                        generation: payload.inventory.observedGeneration,
                        mode: payload.request.mode
                    ),
                    requested,
                    measuredLimits
                )
            ]
        )
    }

    private func reserve(_ charge: ExecutionCharge) throws {
        var nextValues: [(BudgetAuthorityKey, BudgetCharge)] = []
        for entry in charge.entries {
            let current = activeBudgetByKey[entry.key] ?? .zero
            let next = try current.adding(entry.requested)
            guard next.memoryBytes <= entry.limit.memoryBytes,
                  next.computeUnits <= entry.limit.computeUnits,
                  next.concurrencyUnits <= entry.limit.concurrencyUnits else {
                throw AcceleratorXPCRequestRegistryError.budgetLimitExceeded
            }
            nextValues.append((entry.key, next))
        }
        for (key, value) in nextValues {
            activeBudgetByKey[key] = value
        }
    }

    private func releaseBudget(for digest: AcceleratorDigest) {
        guard let reservations = budgetReservationByDigest.removeValue(forKey: digest) else {
            return
        }
        for reservation in reservations {
            guard let current = activeBudgetByKey[reservation.key] else { continue }
            let remaining = current.subtracting(reservation.charge)
            if remaining == .zero {
                activeBudgetByKey.removeValue(forKey: reservation.key)
            } else {
                activeBudgetByKey[reservation.key] = remaining
            }
        }
    }

    public func connectionInvalidated() {
        // A broken transport is not an authorization to cancel or revoke work.
    }

    private static func replayed(
        _ response: AcceleratorXPCResponse
    ) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: response.operation,
            requestID: response.requestID,
            status: response.status,
            idempotencyDigest: response.idempotencyDigest,
            serviceProof: response.serviceProof,
            payload: response.payload,
            error: response.error,
            replayed: true,
            protocolVersion: response.protocolVersion
        )
    }
}

public enum AcceleratorXPCServiceError: Error, Equatable, Sendable {
    case registry(AcceleratorXPCRequestRegistryError)
    case invalidResponse
}

private extension AcceleratorXPCRequest {
    var observedAt: Date {
        switch payload {
        case .inventory(let query):
            query.observedAt
        case .status(let query):
            query.observedAt
        case .execute(let payload):
            payload.observedAt
        case .cancel(let payload):
            payload.observedAt
        case .revoke(let payload):
            payload.observedAt
        }
    }
}

public final class AcceleratorXPCService: @unchecked Sendable {
    public let serviceProof: AcceleratorXPCCodeIdentityProof
    public let identityInspector: any AcceleratorXPCIdentityInspector
    public let registry: AcceleratorXPCRequestRegistry

    private let backend: (any AcceleratorXPCBackend)?
    private let durableReplayStore: (any AcceleratorXPCDurableReplayStore)?

    public convenience init(
        backend: (any AcceleratorXPCBackend)? = nil,
        maxConcurrent: Int = AcceleratorLimits.maxConcurrency,
        identityInspector: any AcceleratorXPCIdentityInspector = AcceleratorXPCLiveIdentityInspector(),
        registry: AcceleratorXPCRequestRegistry? = nil
    ) throws {
        try self.init(
            backend: backend,
            maxConcurrent: maxConcurrent,
            identityInspector: identityInspector,
            registry: registry,
            durableReplayStore: nil
        )
    }

    package init(
        backend: (any AcceleratorXPCBackend)? = nil,
        maxConcurrent: Int = AcceleratorLimits.maxConcurrency,
        identityInspector: any AcceleratorXPCIdentityInspector = AcceleratorXPCLiveIdentityInspector(),
        registry: AcceleratorXPCRequestRegistry? = nil,
        durableReplayStore: (any AcceleratorXPCDurableReplayStore)?
    ) throws {
        let proof = try identityInspector.current()
        try proof.validate(as: .service)
        self.serviceProof = proof
        self.identityInspector = identityInspector
        self.backend = backend
        self.registry = try registry ?? AcceleratorXPCRequestRegistry(maxConcurrent: maxConcurrent)
        self.durableReplayStore = durableReplayStore
    }

    public func handle(
        _ request: AcceleratorXPCRequest,
        peer: AcceleratorXPCCodeIdentityProof
    ) async throws -> AcceleratorXPCResponse {
        try peer.validate(as: .daemon)

        return try await handleTransportAuthenticated(request)
    }

    func handleTransportAuthenticated(
        _ request: AcceleratorXPCRequest
    ) async throws -> AcceleratorXPCResponse {
        let admission: AcceleratorXPCRequestAdmission
        do {
            admission = try registry.begin(request)
        } catch let error as AcceleratorXPCRequestRegistryError {
            throw AcceleratorXPCServiceError.registry(error)
        }
        if case .replayed(let response) = admission {
            return response
        }

        let durableIdentity: AcceleratorXPCDurableReplayIdentity?
        if let durableReplayStore {
            do {
                let identity = try AcceleratorXPCDurableReplayIdentity(
                    requestID: request.requestID,
                    operation: request.operation.rawValue,
                    protocolVersion: request.protocolVersion,
                    idempotencyDigest: request.idempotencyDigest
                )
                switch try durableReplayStore.begin(
                    identity,
                    observedAt: request.observedAt
                ) {
                case .admitted:
                    durableIdentity = identity
                case .inFlight:
                    registry.abandon(request)
                    throw AcceleratorXPCServiceError.registry(
                        .replayHistoryUnavailable
                    )
                case .replayed(let data):
                    let stored = try AcceleratorXPCWireJSON.decode(
                        AcceleratorXPCResponse.self,
                        from: data
                    )
                    guard stored.requestID == request.requestID,
                          stored.operation == request.operation,
                          stored.protocolVersion == request.protocolVersion,
                          stored.idempotencyDigest == request.idempotencyDigest,
                          stored.serviceProof == serviceProof else {
                        registry.abandon(request)
                        throw AcceleratorXPCServiceError.invalidResponse
                    }
                    let replay = try replayed(stored)
                    _ = registry.finish(request, response: replay)
                    return replay
                }
            } catch let error as AcceleratorXPCServiceError {
                throw error
            } catch let error as AcceleratorXPCDurableReplayStoreError {
                registry.abandon(request)
                switch error {
                case .idempotencyConflict:
                    throw AcceleratorXPCServiceError.registry(.idempotencyConflict)
                case .invalidPersistedRecord:
                    throw AcceleratorXPCServiceError.invalidResponse
                case .invalidIdentity, .responseTooLarge, .storageUnavailable:
                    throw AcceleratorXPCServiceError.registry(
                        .replayHistoryUnavailable
                    )
                }
            } catch {
                registry.abandon(request)
                throw AcceleratorXPCServiceError.registry(
                    .replayHistoryUnavailable
                )
            }
        } else {
            durableIdentity = nil
        }

        do {
            let response = try await process(request)
            let retained = registry.executionIsRetained(request)
            if retained {
                let ready = registry.finish(request, response: response)
                if ready {
                    completeDurableReplay(
                        durableIdentity,
                        request: request,
                        response: response
                    )
                    registry.releaseHeldExecution(request)
                }
            } else {
                try persistDurableReplay(
                    durableIdentity,
                    request: request,
                    response: response
                )
                _ = registry.finish(request, response: response)
            }
            return response
        } catch {
            registry.abandon(request)
            throw error
        }
    }

    private func replayIdentity(
        for request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCDurableReplayIdentity {
        try AcceleratorXPCDurableReplayIdentity(
            requestID: request.requestID,
            operation: request.operation.rawValue,
            protocolVersion: request.protocolVersion,
            idempotencyDigest: request.idempotencyDigest
        )
    }

    private func replayed(
        _ response: AcceleratorXPCResponse
    ) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: response.operation,
            requestID: response.requestID,
            status: response.status,
            idempotencyDigest: response.idempotencyDigest,
            serviceProof: response.serviceProof,
            payload: response.payload,
            error: response.error,
            replayed: true,
            protocolVersion: response.protocolVersion
        )
    }

    private func persistDurableReplay(
        _ identity: AcceleratorXPCDurableReplayIdentity?,
        request: AcceleratorXPCRequest,
        response: AcceleratorXPCResponse
    ) throws {
        guard let durableReplayStore, let identity else { return }
        do {
            let data = try AcceleratorXPCWireJSON.encode(response)
            try durableReplayStore.complete(
                identity,
                response: data,
                observedAt: request.observedAt
            )
        } catch {
            throw AcceleratorXPCServiceError.registry(
                .replayHistoryUnavailable
            )
        }
    }

    private func completeDurableReplay(
        _ identity: AcceleratorXPCDurableReplayIdentity?,
        request: AcceleratorXPCRequest,
        response: AcceleratorXPCResponse
    ) {
        if let durableReplayStore, let identity {
            do {
                let data = try AcceleratorXPCWireJSON.encode(response)
                try durableReplayStore.complete(
                    identity,
                    response: data,
                    observedAt: request.observedAt
                )
            } catch {
                // The backend has terminated, so releasing the charge is safe.
                // The durable pending record remains a fail-closed replay fence.
            }
        }
        registry.releaseHeldExecution(request)
    }

    private func process(
        _ request: AcceleratorXPCRequest
    ) async throws -> AcceleratorXPCResponse {
        switch request.payload {
        case .inventory(let query):
            guard let backend else {
                return try unavailable(request, code: .backendUnavailable)
            }
            do {
                let inventory = try await withTimeout(milliseconds: request.timeoutMilliseconds) {
                    try await backend.inventory(for: query)
                }
                guard inventory.hostID == query.hostID else {
                    return try rejected(request, code: .inventoryMismatch)
                }
                return try completed(request, payload: .inventory(inventory))
            } catch is AcceleratorXPCTimeoutError {
                return try timedOut(request)
            } catch let error as AcceleratorXPCBackendError {
                return try unavailable(
                    request,
                    code: error == .unsupported ? .backendUnsupported : .backendUnavailable
                )
            } catch {
                return try unavailable(request, code: .serviceUnavailable)
            }

        case .status(let query):
            guard let backend else {
                return try unavailable(request, code: .backendUnavailable)
            }
            do {
                let status = try await withTimeout(milliseconds: request.timeoutMilliseconds) {
                    try await backend.status(for: query)
                }
                guard status.hostID == query.hostID,
                      status.inventorySnapshotID == query.inventorySnapshotID,
                      status.inventoryGeneration == query.inventoryGeneration else {
                    return try rejected(request, code: .inventoryMismatch)
                }
                return try completed(request, payload: .status(status))
            } catch is AcceleratorXPCTimeoutError {
                return try timedOut(request)
            } catch let error as AcceleratorXPCBackendError {
                return try unavailable(
                    request,
                    code: error == .unsupported ? .backendUnsupported : .backendUnavailable
                )
            } catch {
                return try unavailable(request, code: .serviceUnavailable)
            }

        case .execute(let payload):
            return try await processExecute(request, payload: payload)

        case .cancel(let payload):
            let binding = AcceleratorXPCExecutionBinding(
                request: payload.executionRequest,
                claim: payload.claim,
                grant: payload.grant,
                reservation: payload.reservation,
                inventory: payload.inventory
            )
            try registry.cancel(
                binding: binding,
                cancellationID: payload.cancellation.cancellationID
            )
            let acknowledgement = try AcceleratorXPCMutationAcknowledgement(
                operation: .cancel,
                targetIdentifier: payload.executionRequest.requestID.uuidString.lowercased(),
                observedAt: payload.observedAt,
                fence: payload.executionRequest.fence
            )
            return try completed(request, payload: .acknowledgement(acknowledgement))

        case .revoke(let payload):
            try registry.revoke(payload: payload)
            let acknowledgement = try AcceleratorXPCMutationAcknowledgement(
                operation: .revoke,
                targetIdentifier: payload.revocation.targetIdentifier,
                observedAt: payload.observedAt,
                fence: payload.revocation.fence
            )
            return try completed(request, payload: .acknowledgement(acknowledgement))
        }
    }

    private func processExecute(
        _ request: AcceleratorXPCRequest,
        payload: AcceleratorXPCExecutePayload
    ) async throws -> AcceleratorXPCResponse {
        let binding = AcceleratorXPCExecutionBinding(
            request: payload.request,
            claim: payload.claim,
            grant: payload.grant,
            reservation: payload.reservation,
            inventory: payload.inventory
        )
        if registry.isCancelled(binding: binding) {
            return try cancelled(request)
        }
        if registry.isRevoked(payload) {
            return try revoked(request)
        }
        guard let backend else {
            return try unavailable(request, code: .backendUnavailable)
        }

        let cancellationHandle = AcceleratorXPCTaskCancellationHandle()
        let timeoutState = AcceleratorXPCTimeoutState()
        let executionTask = Task<AcceleratorExecutionResult, Error> {
            let artifact = try await backend.modelArtifact(for: payload.request.modelHash)
            let context = try AcceleratorXPCBackendExecutionContext(
                payload: payload,
                modelArtifact: artifact
            )
            return try await backend.execute(context)
        }
        cancellationHandle.install { executionTask.cancel() }
        registry.registerExecution(
            binding: binding,
            cancellation: { cancellationHandle.cancel() }
        )
        var retainedUntilTermination = false
        defer {
            if !retainedUntilTermination {
                registry.unregisterExecution(binding: binding)
                executionTask.cancel()
            }
        }

        do {
            let result = try await withTimeout(
                milliseconds: request.timeoutMilliseconds,
                onTimeout: {
                    await timeoutState.markTriggered()
                    cancellationHandle.cancel()
                }
            ) {
                try await executionTask.value
            }
            if await timeoutState.wasTriggered() {
                return try timedOut(request)
            }
            if registry.isCancelled(binding: binding) {
                return try cancelled(request)
            }
            if registry.isRevoked(payload) {
                return try revoked(request)
            }
            try result.validate(
                against: payload.request,
                inventory: payload.inventory
            )
            if let provenance = result.provenance {
                guard provenance.inventorySnapshotID == payload.inventory.snapshotID,
                      provenance.inventoryGeneration == payload.inventory.observedGeneration else {
                    return try rejected(request, code: .inventoryMismatch)
                }
            }
            return try completed(request, payload: .execution(result))
        } catch is AcceleratorXPCTimeoutError {
            cancellationHandle.cancel()
            retainedUntilTermination = true
            let response = try timedOut(request)
            superviseTimedOutExecution(
                request: request,
                binding: binding,
                executionTask: executionTask
            )
            return response
        } catch is AcceleratorXPCWorkerTerminationUncertain {
            retainedUntilTermination = true
            registry.retainExecutionUntilTermination(request)
            return try unavailable(request, code: .serviceUnavailable)
        } catch let error as AcceleratorXPCBackendError {
            return try unavailable(
                request,
                code: error == .unsupported ? .backendUnsupported : .backendUnavailable
            )
        } catch is CancellationError {
            if await timeoutState.wasTriggered() {
                retainedUntilTermination = true
                let response = try timedOut(request)
                superviseTimedOutExecution(
                    request: request,
                    binding: binding,
                    executionTask: executionTask
                )
                return response
            }
            cancellationHandle.cancel()
            if registry.isRevoked(payload) {
                return try revoked(request)
            }
            return try cancelled(request)
        } catch let error as AcceleratorXPCValidationError {
            _ = error
            return try rejected(request, code: .invalidResponse)
        } catch is AcceleratorValidationError {
            return try rejected(request, code: .invalidResponse)
        } catch {
            if await timeoutState.wasTriggered() {
                retainedUntilTermination = true
                let response = try timedOut(request)
                superviseTimedOutExecution(
                    request: request,
                    binding: binding,
                    executionTask: executionTask
                )
                return response
            }
            return try unavailable(request, code: .serviceUnavailable)
        }
    }

    private func superviseTimedOutExecution(
        request: AcceleratorXPCRequest,
        binding: AcceleratorXPCExecutionBinding,
        executionTask: Task<AcceleratorExecutionResult, Error>
    ) {
        registry.retainExecutionUntilTermination(request)
        Task { [self] in
            _ = try? await executionTask.value
            if let response = registry.markExecutionTerminated(binding: binding) {
                completeDurableReplay(
                    try? replayIdentity(for: request),
                    request: request,
                    response: response
                )
            }
        }
    }

    private func completed(
        _ request: AcceleratorXPCRequest,
        payload: AcceleratorXPCResponsePayload
    ) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: request.operation,
            requestID: request.requestID,
            status: .completed,
            idempotencyDigest: request.idempotencyDigest,
            serviceProof: serviceProof,
            payload: payload
        )
    }

    private func unavailable(
        _ request: AcceleratorXPCRequest,
        code: AcceleratorXPCErrorCode
    ) throws -> AcceleratorXPCResponse {
        try failed(request, status: .unavailable, code: code)
    }

    private func rejected(
        _ request: AcceleratorXPCRequest,
        code: AcceleratorXPCErrorCode
    ) throws -> AcceleratorXPCResponse {
        try failed(request, status: .rejected, code: code)
    }

    private func cancelled(
        _ request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCResponse {
        try failed(request, status: .cancelled, code: .cancelled)
    }

    private func revoked(
        _ request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCResponse {
        try failed(request, status: .revoked, code: .revoked)
    }

    private func timedOut(
        _ request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCResponse {
        try failed(request, status: .timedOut, code: .timeout)
    }

    private func failed(
        _ request: AcceleratorXPCRequest,
        status: AcceleratorXPCResponseStatus,
        code: AcceleratorXPCErrorCode
    ) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: request.operation,
            requestID: request.requestID,
            status: status,
            idempotencyDigest: request.idempotencyDigest,
            serviceProof: serviceProof,
            error: try AcceleratorXPCError(code: code)
        )
    }

    private struct AcceleratorXPCTimeoutError: Error {}

    private func withTimeout<T: Sendable>(
        milliseconds: Int,
        onTimeout: @escaping @Sendable () async -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = AcceleratorXPCTimeoutRace<T>()
        let operationTask = Task {
            do {
                race.resolve(.success(try await operation()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                await onTimeout()
                operationTask.cancel()
                race.resolve(.failure(AcceleratorXPCTimeoutError()))
            } catch {
                race.resolve(.failure(error))
            }
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await race.wait()
        } onCancel: {
            operationTask.cancel()
            race.resolve(.failure(CancellationError()))
        }
    }
}

public enum AcceleratorXPCServiceRuntime {
    public static func run(
        serviceName: String = AcceleratorXPCIdentityPolicy.serviceIdentifier
    ) -> Never {
        run(serviceName: serviceName, durableReplayStore: nil)
    }

    package static func run(
        serviceName: String = AcceleratorXPCIdentityPolicy.serviceIdentifier,
        durableReplayStore: (any AcceleratorXPCDurableReplayStore)?
    ) -> Never {
        guard let service = try? AcceleratorXPCService(
            durableReplayStore: durableReplayStore
        ) else {
            Darwin.exit(78)
        }
        let listenerQueue = DispatchQueue(label: "dev.hostwright.phase10.accelerator.listener")
        let listener = xpc_connection_create_mach_service(
            serviceName,
            listenerQueue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(listener) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let peer = event
            guard xpc_connection_set_peer_code_signing_requirement(
                peer,
                AcceleratorXPCIdentityPolicy.daemonRequirement
            ) == 0 else {
                xpc_connection_set_event_handler(peer) { _ in }
                xpc_connection_activate(peer)
                xpc_connection_cancel(peer)
                return
            }
            AcceleratorXPCServiceSession(
                service: service,
                connection: peer
            ).activate()
        }
        xpc_connection_activate(listener)
        dispatchMain()
    }
}

private final class AcceleratorXPCServiceSession: @unchecked Sendable {
    private let service: AcceleratorXPCService
    private let connection: xpc_connection_t

    init(
        service: AcceleratorXPCService,
        connection: xpc_connection_t
    ) {
        self.service = service
        self.connection = connection
    }

    func activate() {
        xpc_connection_set_event_handler(connection) { [self] event in
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                service.registryConnectionInvalidated()
                return
            }
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
            Task.detached { [service, connection, event] in
                guard let request = try? AcceleratorXPCMessageCodec.decodeRequest(event),
                      let response = try? await service.handleTransportAuthenticated(request),
                      let encoded = try? AcceleratorXPCMessageCodec.encodeResponse(response) else {
                    return
                }
                xpc_connection_send_message(connection, encoded)
            }
        }
        xpc_connection_activate(connection)
    }
}

private extension AcceleratorXPCService {
    func registryConnectionInvalidated() {
        registry.connectionInvalidated()
    }
}

private final class AcceleratorXPCTaskCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    private var wasCancelled = false

    func install(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            cancellation()
            return
        }
        self.cancellation = cancellation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let cancellation = self.cancellation
        lock.unlock()
        cancellation?()
    }
}

private final class AcceleratorXPCTimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private actor AcceleratorXPCTimeoutState {
    private var triggered = false

    func markTriggered() {
        triggered = true
    }

    func wasTriggered() -> Bool {
        triggered
    }
}
