import Foundation

public enum AcceleratorReservationState: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case reserved
    case committed
    case released
    case cancelled
    case revoked
}

public enum AcceleratorReservationTransition: String, Codable, CaseIterable, Equatable, Sendable {
    case commit
    case release
    case cancel
    case revoke
}

public struct AcceleratorReservation: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let reservationID: UUID
    public let claimID: UUID
    public let scope: AcceleratorScope
    public let mode: AcceleratorExecutionMode
    public let modelHash: AcceleratorDigest?
    public let budget: AcceleratorBudgetVector
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let fence: AcceleratorFence
    public let owner: AcceleratorAuthenticationContext
    public let createdAt: Date
    public let expiresAt: Date
    public let state: AcceleratorReservationState
    public let lastTransitionAt: Date

    public init(
        reservationID: UUID,
        claimID: UUID,
        scope: AcceleratorScope,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest?,
        budget: AcceleratorBudgetVector,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        fence: AcceleratorFence,
        owner: AcceleratorAuthenticationContext,
        createdAt: Date,
        expiresAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try self.init(
            contractVersion: contractVersion,
            reservationID: reservationID,
            claimID: claimID,
            scope: scope,
            mode: mode,
            modelHash: modelHash,
            budget: budget,
            inventorySnapshotID: inventorySnapshotID,
            inventoryGeneration: inventoryGeneration,
            fence: fence,
            owner: owner,
            createdAt: createdAt,
            expiresAt: expiresAt,
            state: .reserved,
            lastTransitionAt: createdAt
        )
    }

    internal init(
        contractVersion: Int,
        reservationID: UUID,
        claimID: UUID,
        scope: AcceleratorScope,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest?,
        budget: AcceleratorBudgetVector,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        fence: AcceleratorFence,
        owner: AcceleratorAuthenticationContext,
        createdAt: Date,
        expiresAt: Date,
        state: AcceleratorReservationState,
        lastTransitionAt: Date
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(reservationID, field: "reservationID")
        try AcceleratorValidation.uuid(claimID, field: "claimID")
        try AcceleratorValidation.scope(scope)
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        try AcceleratorValidation.uuid(
            inventorySnapshotID,
            field: "inventorySnapshotID"
        )
        try AcceleratorValidation.positiveGeneration(
            inventoryGeneration,
            field: "inventoryGeneration"
        )
        try AcceleratorValidation.dateRange(
            start: createdAt,
            end: expiresAt,
            startField: "createdAt",
            endField: "expiresAt"
        )
        try AcceleratorValidation.date(
            lastTransitionAt,
            field: "lastTransitionAt"
        )
        guard owner.isActive(at: createdAt) else {
            throw AcceleratorValidation.fail(
                .authenticationExpired,
                "owner"
            )
        }
        switch state {
        case .reserved:
            guard lastTransitionAt == createdAt else {
                throw AcceleratorValidation.fail(
                    .invalidReservation,
                    "lastTransitionAt"
                )
            }
        case .committed, .released, .cancelled, .revoked:
            guard lastTransitionAt > createdAt else {
                throw AcceleratorValidation.fail(
                    .invalidReservation,
                    "lastTransitionAt"
                )
            }
        }
        self.contractVersion = contractVersion
        self.reservationID = reservationID
        self.claimID = claimID
        self.scope = scope
        self.mode = mode
        self.modelHash = modelHash
        self.budget = budget
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.fence = fence
        self.owner = owner
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
        self.lastTransitionAt = lastTransitionAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case reservationID
        case claimID
        case scope
        case mode
        case modelHash
        case budget
        case inventorySnapshotID
        case inventoryGeneration
        case fence
        case owner
        case createdAt
        case expiresAt
        case state
        case lastTransitionAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contractVersion: container.decode(Int.self, forKey: .contractVersion),
            reservationID: container.decode(UUID.self, forKey: .reservationID),
            claimID: container.decode(UUID.self, forKey: .claimID),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            mode: container.decode(
                AcceleratorExecutionMode.self,
                forKey: .mode
            ),
            modelHash: container.decodeIfPresent(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            budget: container.decode(
                AcceleratorBudgetVector.self,
                forKey: .budget
            ),
            inventorySnapshotID: container.decode(
                UUID.self,
                forKey: .inventorySnapshotID
            ),
            inventoryGeneration: container.decode(
                Int64.self,
                forKey: .inventoryGeneration
            ),
            fence: container.decode(AcceleratorFence.self, forKey: .fence),
            owner: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .owner
            ),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            state: container.decode(
                AcceleratorReservationState.self,
                forKey: .state
            ),
            lastTransitionAt: container.decode(
                Date.self,
                forKey: .lastTransitionAt
            )
        )
    }
}

public struct AcceleratorReservationTransitionRequest:
    Codable,
    Equatable,
    Sendable
{
    public let contractVersion: Int
    public let transition: AcceleratorReservationTransition
    public let reservationID: UUID
    public let scope: AcceleratorScope
    public let fence: AcceleratorFence
    public let actor: AcceleratorAuthenticationContext
    public let observedAt: Date

    public init(
        transition: AcceleratorReservationTransition,
        reservationID: UUID,
        scope: AcceleratorScope,
        fence: AcceleratorFence,
        actor: AcceleratorAuthenticationContext,
        observedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) {
        self.contractVersion = contractVersion
        self.transition = transition
        self.reservationID = reservationID
        self.scope = scope
        self.fence = fence
        self.actor = actor
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case transition
        case reservationID
        case scope
        case fence
        case actor
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            transition: try container.decode(
                AcceleratorReservationTransition.self,
                forKey: .transition
            ),
            reservationID: try container.decode(UUID.self, forKey: .reservationID),
            scope: try container.decode(AcceleratorScope.self, forKey: .scope),
            fence: try container.decode(AcceleratorFence.self, forKey: .fence),
            actor: try container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .actor
            ),
            observedAt: try container.decode(Date.self, forKey: .observedAt),
            contractVersion: try container.decode(Int.self, forKey: .contractVersion)
        )
        try AcceleratorValidation.version(value.contractVersion)
        try AcceleratorValidation.uuid(value.reservationID, field: "reservationID")
        try AcceleratorValidation.date(value.observedAt, field: "observedAt")
        self = value
    }
}

public struct AcceleratorReservationStateMachine: Sendable {
    public init() {}

    public func transition(
        reservation: AcceleratorReservation,
        request: AcceleratorReservationTransitionRequest
    ) throws -> AcceleratorReservation {
        try AcceleratorValidation.version(reservation.contractVersion)
        try AcceleratorValidation.version(request.contractVersion)
        try AcceleratorValidation.scope(request.scope)
        try AcceleratorValidation.uuid(
            request.reservationID,
            field: "reservationID"
        )
        guard request.reservationID == reservation.reservationID else {
            throw AcceleratorValidation.fail(
                .requestMismatch,
                "reservationID"
            )
        }
        guard request.scope == reservation.scope else {
            throw AcceleratorValidation.fail(.scopeMismatch, "scope")
        }
        try AcceleratorValidation.date(request.observedAt, field: "observedAt")
        guard request.fence.nodeEpoch == reservation.fence.nodeEpoch else {
            throw AcceleratorValidation.fail(.staleNodeEpoch, "nodeEpoch")
        }
        guard request.fence.reservationSequence
            == reservation.fence.reservationSequence else {
            throw AcceleratorValidation.fail(
                .staleReservationSequence,
                "reservationSequence"
            )
        }
        try request.actor.validateActive(at: request.observedAt)
        guard request.observedAt > reservation.lastTransitionAt else {
            throw AcceleratorValidation.fail(
                .outOfOrderObservation,
                "observedAt"
            )
        }
        guard request.transition != .commit
            || request.observedAt <= reservation.expiresAt else {
            throw AcceleratorValidation.fail(.expired, "observedAt")
        }

        let nextState: AcceleratorReservationState
        switch (reservation.state, request.transition) {
        case (.reserved, .commit):
            nextState = .committed
        case (.reserved, .cancel):
            nextState = .cancelled
        case (.reserved, .revoke):
            nextState = .revoked
        case (.committed, .release):
            nextState = .released
        case (.committed, .cancel):
            nextState = .cancelled
        case (.committed, .revoke):
            nextState = .revoked
        case (.released, _), (.cancelled, _), (.revoked, _):
            throw AcceleratorValidation.fail(.terminalState, "state")
        case (.reserved, .release), (.committed, .commit):
            throw AcceleratorValidation.fail(.invalidTransition, "transition")
        }

        return try AcceleratorReservation(
            contractVersion: reservation.contractVersion,
            reservationID: reservation.reservationID,
            claimID: reservation.claimID,
            scope: reservation.scope,
            mode: reservation.mode,
            modelHash: reservation.modelHash,
            budget: reservation.budget,
            inventorySnapshotID: reservation.inventorySnapshotID,
            inventoryGeneration: reservation.inventoryGeneration,
            fence: reservation.fence,
            owner: reservation.owner,
            createdAt: reservation.createdAt,
            expiresAt: reservation.expiresAt,
            state: nextState,
            lastTransitionAt: request.observedAt
        )
    }
}

public struct AcceleratorGrant: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let grantID: UUID
    public let claimID: UUID
    public let reservationID: UUID
    public let scope: AcceleratorScope
    public let granteeSubjectID: String
    public let mode: AcceleratorExecutionMode
    public let modelHash: AcceleratorDigest?
    public let quota: AcceleratorQuota
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let fence: AcceleratorFence
    public let issuer: AcceleratorAuthenticationContext
    public let issuedAt: Date
    public let expiresAt: Date

    public init(
        grantID: UUID,
        claimID: UUID,
        reservationID: UUID,
        scope: AcceleratorScope,
        granteeSubjectID: String,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest?,
        quota: AcceleratorQuota,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        fence: AcceleratorFence,
        issuer: AcceleratorAuthenticationContext,
        issuedAt: Date,
        expiresAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(grantID, field: "grantID")
        try AcceleratorValidation.uuid(claimID, field: "claimID")
        try AcceleratorValidation.uuid(
            reservationID,
            field: "reservationID"
        )
        try AcceleratorValidation.scope(scope)
        try AcceleratorValidation.identifier(
            granteeSubjectID,
            field: "granteeSubjectID"
        )
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        try AcceleratorValidation.uuid(
            inventorySnapshotID,
            field: "inventorySnapshotID"
        )
        try AcceleratorValidation.positiveGeneration(
            inventoryGeneration,
            field: "inventoryGeneration"
        )
        try AcceleratorValidation.dateRange(
            start: issuedAt,
            end: expiresAt,
            startField: "issuedAt",
            endField: "expiresAt"
        )
        try issuer.validateActive(at: issuedAt)
        self.contractVersion = contractVersion
        self.grantID = grantID
        self.claimID = claimID
        self.reservationID = reservationID
        self.scope = scope
        self.granteeSubjectID = granteeSubjectID
        self.mode = mode
        self.modelHash = modelHash
        self.quota = quota
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.fence = fence
        self.issuer = issuer
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case grantID
        case claimID
        case reservationID
        case scope
        case granteeSubjectID
        case mode
        case modelHash
        case quota
        case inventorySnapshotID
        case inventoryGeneration
        case fence
        case issuer
        case issuedAt
        case expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            grantID: container.decode(UUID.self, forKey: .grantID),
            claimID: container.decode(UUID.self, forKey: .claimID),
            reservationID: container.decode(UUID.self, forKey: .reservationID),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            granteeSubjectID: container.decode(
                String.self,
                forKey: .granteeSubjectID
            ),
            mode: container.decode(
                AcceleratorExecutionMode.self,
                forKey: .mode
            ),
            modelHash: container.decodeIfPresent(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            quota: container.decode(AcceleratorQuota.self, forKey: .quota),
            inventorySnapshotID: container.decode(
                UUID.self,
                forKey: .inventorySnapshotID
            ),
            inventoryGeneration: container.decode(
                Int64.self,
                forKey: .inventoryGeneration
            ),
            fence: container.decode(AcceleratorFence.self, forKey: .fence),
            issuer: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .issuer
            ),
            issuedAt: container.decode(Date.self, forKey: .issuedAt),
            expiresAt: container.decode(Date.self, forKey: .expiresAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorExecutionRequest: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let requestID: UUID
    public let grantID: UUID
    public let reservationID: UUID
    public let scope: AcceleratorScope
    public let mode: AcceleratorExecutionMode
    public let modelHash: AcceleratorDigest
    public let inputDigest: AcceleratorDigest
    public let inputBytes: Int
    public let outputLimitBytes: Int
    public let timeoutMilliseconds: Int
    public let budget: AcceleratorBudgetVector
    public let fence: AcceleratorFence
    public let authentication: AcceleratorAuthenticationContext
    public let requestedAt: Date

    public init(
        requestID: UUID,
        grantID: UUID,
        reservationID: UUID,
        scope: AcceleratorScope,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest,
        inputDigest: AcceleratorDigest,
        inputBytes: Int,
        outputLimitBytes: Int,
        timeoutMilliseconds: Int,
        budget: AcceleratorBudgetVector,
        fence: AcceleratorFence,
        authentication: AcceleratorAuthenticationContext,
        requestedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(requestID, field: "requestID")
        try AcceleratorValidation.uuid(grantID, field: "grantID")
        try AcceleratorValidation.uuid(
            reservationID,
            field: "reservationID"
        )
        try AcceleratorValidation.scope(scope)
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        guard (1...AcceleratorLimits.maxInputBytes).contains(inputBytes) else {
            throw AcceleratorValidation.fail(
                .inputLimitExceeded,
                "inputBytes"
            )
        }
        guard (1...AcceleratorLimits.maxOutputBytes).contains(
            outputLimitBytes
        ) else {
            throw AcceleratorValidation.fail(
                .outputLimitExceeded,
                "outputLimitBytes"
            )
        }
        guard (1...AcceleratorLimits.maxTimeoutMilliseconds).contains(
            timeoutMilliseconds
        ) else {
            throw AcceleratorValidation.fail(
                .timeoutLimitExceeded,
                "timeoutMilliseconds"
            )
        }
        try AcceleratorValidation.date(requestedAt, field: "requestedAt")
        try authentication.validateActive(at: requestedAt)
        self.contractVersion = contractVersion
        self.requestID = requestID
        self.grantID = grantID
        self.reservationID = reservationID
        self.scope = scope
        self.mode = mode
        self.modelHash = modelHash
        self.inputDigest = inputDigest
        self.inputBytes = inputBytes
        self.outputLimitBytes = outputLimitBytes
        self.timeoutMilliseconds = timeoutMilliseconds
        self.budget = budget
        self.fence = fence
        self.authentication = authentication
        self.requestedAt = requestedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case requestID
        case grantID
        case reservationID
        case scope
        case mode
        case modelHash
        case inputDigest
        case inputBytes
        case outputLimitBytes
        case timeoutMilliseconds
        case budget
        case fence
        case authentication
        case requestedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(UUID.self, forKey: .requestID),
            grantID: container.decode(UUID.self, forKey: .grantID),
            reservationID: container.decode(UUID.self, forKey: .reservationID),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            mode: container.decode(
                AcceleratorExecutionMode.self,
                forKey: .mode
            ),
            modelHash: container.decode(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            inputDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .inputDigest
            ),
            inputBytes: container.decode(Int.self, forKey: .inputBytes),
            outputLimitBytes: container.decode(
                Int.self,
                forKey: .outputLimitBytes
            ),
            timeoutMilliseconds: container.decode(
                Int.self,
                forKey: .timeoutMilliseconds
            ),
            budget: container.decode(
                AcceleratorBudgetVector.self,
                forKey: .budget
            ),
            fence: container.decode(AcceleratorFence.self, forKey: .fence),
            authentication: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .authentication
            ),
            requestedAt: container.decode(Date.self, forKey: .requestedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorExecutionContract {
    public static func validate(
        request: AcceleratorExecutionRequest,
        claim: AcceleratorClaim,
        grant: AcceleratorGrant,
        reservation: AcceleratorReservation,
        inventory: AcceleratorInventorySnapshot,
        observedAt: Date
    ) throws {
        try AcceleratorValidation.version(request.contractVersion)
        try AcceleratorValidation.version(claim.contractVersion)
        try AcceleratorValidation.version(grant.contractVersion)
        try AcceleratorValidation.version(reservation.contractVersion)
        try AcceleratorValidation.version(inventory.contractVersion)
        try AcceleratorValidation.date(observedAt, field: "observedAt")
        guard request.requestedAt <= observedAt else {
            throw AcceleratorValidation.fail(
                .outOfOrderObservation,
                "requestedAt"
            )
        }
        try request.authentication.validateActive(at: observedAt)
        try grant.issuer.validateActive(at: observedAt)
        guard request.authentication.subjectID == grant.granteeSubjectID else {
            throw AcceleratorValidation.fail(
                .grantMismatch,
                "granteeSubjectID"
            )
        }
        guard grant.issuer == claim.issuer else {
            throw AcceleratorValidation.fail(.grantMismatch, "issuer")
        }
        guard claim.scope.contains(grant.scope),
              grant.scope == reservation.scope,
              reservation.scope == request.scope else {
            throw AcceleratorValidation.fail(.scopeMismatch, "scope")
        }
        guard grant.claimID == claim.claimID,
              reservation.claimID == claim.claimID,
              grant.reservationID == reservation.reservationID,
              request.grantID == grant.grantID,
              request.reservationID == reservation.reservationID else {
            throw AcceleratorValidation.fail(.requestMismatch, "identity")
        }
        guard reservation.state == .committed else {
            throw AcceleratorValidation.fail(
                .invalidReservation,
                "reservation.state"
            )
        }
        guard claim.allowedModes.contains(request.mode),
              request.mode == grant.mode,
              request.mode == reservation.mode else {
            throw AcceleratorValidation.fail(.modeUnavailable, "mode")
        }
        guard !request.mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        guard let evidence = inventory.evidence(for: request.mode),
              evidence.status == .available,
              evidence.observedGeneration == inventory.observedGeneration else {
            throw AcceleratorValidation.fail(.modeUnavailable, "modeEvidence")
        }
        guard claim.inventorySnapshotID == inventory.snapshotID,
              grant.inventorySnapshotID == inventory.snapshotID,
              reservation.inventorySnapshotID == inventory.snapshotID,
              claim.inventoryGeneration == inventory.observedGeneration,
              grant.inventoryGeneration == inventory.observedGeneration,
              reservation.inventoryGeneration == inventory.observedGeneration else {
            throw AcceleratorValidation.fail(
                .inventoryMismatch,
                "inventory"
            )
        }
        guard reservation.fence == grant.fence,
              grant.fence == request.fence else {
            throw AcceleratorValidation.fail(.staleReservationSequence, "fence")
        }
        if let claimModelHash = claim.modelHash {
            guard claimModelHash == request.modelHash,
                  claimModelHash == grant.modelHash,
                  claimModelHash == reservation.modelHash else {
                throw AcceleratorValidation.fail(
                    .requestMismatch,
                    "modelHash"
                )
            }
        } else {
            guard grant.modelHash == request.modelHash,
                  reservation.modelHash == request.modelHash else {
                throw AcceleratorValidation.fail(
                    .requestMismatch,
                    "modelHash"
                )
            }
        }
        guard grant.issuedAt >= claim.issuedAt,
              grant.expiresAt <= claim.expiresAt,
              request.requestedAt >= grant.issuedAt,
              request.requestedAt <= grant.expiresAt,
              request.requestedAt >= reservation.createdAt,
              request.requestedAt <= reservation.expiresAt else {
            throw AcceleratorValidation.fail(.expired, "requestedAt")
        }
        guard request.inputBytes <= claim.quota.maxInputBytes,
              request.inputBytes <= grant.quota.maxInputBytes,
              request.outputLimitBytes <= claim.quota.maxOutputBytes,
              request.outputLimitBytes <= grant.quota.maxOutputBytes,
              request.timeoutMilliseconds <= claim.quota.maxTimeoutMilliseconds,
              request.timeoutMilliseconds <= grant.quota.maxTimeoutMilliseconds else {
            throw AcceleratorValidation.fail(.budgetExceeded, "limits")
        }
        guard request.budget.fits(in: claim.quota.budget),
              request.budget.fits(in: grant.quota.budget),
              request.budget.fits(in: reservation.budget) else {
            throw AcceleratorValidation.fail(.budgetExceeded, "budget")
        }
        let measuredBudgets: [(AcceleratorBudgetKind, UInt64)] = [
            (.memory, request.budget.memoryBytes),
            (.compute, request.budget.computeUnits),
            (.concurrency, request.budget.concurrencyUnits)
        ]
        for (kind, amount) in measuredBudgets {
            guard let measured = inventory.budget(for: request.mode, kind: kind),
                  measured.observedGeneration == inventory.observedGeneration,
                  measured.amount >= amount else {
                throw AcceleratorValidation.fail(
                    .budgetExceeded,
                    kind.rawValue
                )
            }
        }
    }
}

public struct AcceleratorMeasuredUsage: Codable, Equatable, Hashable, Sendable {
    public let contractVersion: Int
    public let budget: AcceleratorBudgetVector
    public let source: AcceleratorEvidenceSource
    public let observedGeneration: Int64
    public let authenticatedBy: AcceleratorAuthenticationContext
    public let observedAt: Date

    public init(
        budget: AcceleratorBudgetVector,
        source: AcceleratorEvidenceSource,
        observedGeneration: Int64,
        authenticatedBy: AcceleratorAuthenticationContext,
        observedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        guard source == .callerMeasuredUsage
            || source == .metalCurrentAllocatedSize
            || source == .mlxProcessLocalMemory else {
            throw AcceleratorValidation.fail(.invalidUsage, "source")
        }
        try AcceleratorValidation.positiveGeneration(
            observedGeneration,
            field: "observedGeneration"
        )
        try AcceleratorValidation.date(observedAt, field: "observedAt")
        try authenticatedBy.validateActive(at: observedAt)
        self.contractVersion = contractVersion
        self.budget = budget
        self.source = source
        self.observedGeneration = observedGeneration
        self.authenticatedBy = authenticatedBy
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case budget
        case source
        case observedGeneration
        case authenticatedBy
        case observedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            budget: container.decode(
                AcceleratorBudgetVector.self,
                forKey: .budget
            ),
            source: container.decode(
                AcceleratorEvidenceSource.self,
                forKey: .source
            ),
            observedGeneration: container.decode(
                Int64.self,
                forKey: .observedGeneration
            ),
            authenticatedBy: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .authenticatedBy
            ),
            observedAt: container.decode(Date.self, forKey: .observedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public struct AcceleratorExecutionProvenance:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let requestID: UUID
    public let mode: AcceleratorExecutionMode
    public let modelHash: AcceleratorDigest
    public let inventorySnapshotID: UUID
    public let inventoryGeneration: Int64
    public let evidenceDigest: AcceleratorDigest
    public let source: AcceleratorEvidenceSource
    public let authenticatedBy: AcceleratorAuthenticationContext
    public let recordedAt: Date

    public init(
        requestID: UUID,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest,
        inventorySnapshotID: UUID,
        inventoryGeneration: Int64,
        evidenceDigest: AcceleratorDigest,
        source: AcceleratorEvidenceSource,
        authenticatedBy: AcceleratorAuthenticationContext,
        recordedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(requestID, field: "requestID")
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        try AcceleratorValidation.uuid(
            inventorySnapshotID,
            field: "inventorySnapshotID"
        )
        try AcceleratorValidation.positiveGeneration(
            inventoryGeneration,
            field: "inventoryGeneration"
        )
        guard source != .callerMeasuredBudget else {
            throw AcceleratorValidation.fail(
                .invalidProvenance,
                "source"
            )
        }
        try AcceleratorValidation.date(recordedAt, field: "recordedAt")
        try authenticatedBy.validateActive(at: recordedAt)
        self.contractVersion = contractVersion
        self.requestID = requestID
        self.mode = mode
        self.modelHash = modelHash
        self.inventorySnapshotID = inventorySnapshotID
        self.inventoryGeneration = inventoryGeneration
        self.evidenceDigest = evidenceDigest
        self.source = source
        self.authenticatedBy = authenticatedBy
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case requestID
        case mode
        case modelHash
        case inventorySnapshotID
        case inventoryGeneration
        case evidenceDigest
        case source
        case authenticatedBy
        case recordedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(UUID.self, forKey: .requestID),
            mode: container.decode(
                AcceleratorExecutionMode.self,
                forKey: .mode
            ),
            modelHash: container.decode(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            inventorySnapshotID: container.decode(
                UUID.self,
                forKey: .inventorySnapshotID
            ),
            inventoryGeneration: container.decode(
                Int64.self,
                forKey: .inventoryGeneration
            ),
            evidenceDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .evidenceDigest
            ),
            source: container.decode(
                AcceleratorEvidenceSource.self,
                forKey: .source
            ),
            authenticatedBy: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .authenticatedBy
            ),
            recordedAt: container.decode(Date.self, forKey: .recordedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorExecutionOutcome: String, Codable, CaseIterable, Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut = "timed-out"
    case revoked
}

public struct AcceleratorExecutionResult:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let requestID: UUID
    public let grantID: UUID
    public let reservationID: UUID
    public let scope: AcceleratorScope
    public let mode: AcceleratorExecutionMode
    public let modelHash: AcceleratorDigest
    public let fence: AcceleratorFence
    public let outcome: AcceleratorExecutionOutcome
    public let outputBytes: Int
    public let outputDigest: AcceleratorDigest?
    public let usage: AcceleratorMeasuredUsage?
    public let provenance: AcceleratorExecutionProvenance?
    public let completedAt: Date
    public let authenticatedBy: AcceleratorAuthenticationContext
    public let errorCode: AcceleratorErrorCode?

    public init(
        requestID: UUID,
        grantID: UUID,
        reservationID: UUID,
        scope: AcceleratorScope,
        mode: AcceleratorExecutionMode,
        modelHash: AcceleratorDigest,
        fence: AcceleratorFence,
        outcome: AcceleratorExecutionOutcome,
        outputBytes: Int,
        outputDigest: AcceleratorDigest?,
        usage: AcceleratorMeasuredUsage?,
        provenance: AcceleratorExecutionProvenance?,
        completedAt: Date,
        authenticatedBy: AcceleratorAuthenticationContext,
        errorCode: AcceleratorErrorCode?,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(requestID, field: "requestID")
        try AcceleratorValidation.uuid(grantID, field: "grantID")
        try AcceleratorValidation.uuid(
            reservationID,
            field: "reservationID"
        )
        try AcceleratorValidation.scope(scope)
        guard !mode.isLinuxGuestPassthrough else {
            throw AcceleratorValidation.fail(
                .linuxGuestPassthroughBlocked,
                "mode"
            )
        }
        guard (0...AcceleratorLimits.maxOutputBytes).contains(outputBytes) else {
            throw AcceleratorValidation.fail(
                .outputLimitExceeded,
                "outputBytes"
            )
        }
        if outputBytes > 0 {
            guard outputDigest != nil else {
                throw AcceleratorValidation.fail(
                    .invalidRequest,
                    "outputDigest"
                )
            }
        } else {
            guard outputDigest == nil else {
                throw AcceleratorValidation.fail(
                    .invalidRequest,
                    "outputDigest"
                )
            }
        }
        switch outcome {
        case .succeeded:
            guard usage != nil, provenance != nil, errorCode == nil else {
                throw AcceleratorValidation.fail(
                    .invalidUsage,
                    "succeeded"
                )
            }
        case .failed, .cancelled, .timedOut, .revoked:
            guard errorCode != nil, outputBytes == 0, outputDigest == nil else {
                throw AcceleratorValidation.fail(
                    .invalidRequest,
                    "failure-result"
                )
            }
        }
        try AcceleratorValidation.date(completedAt, field: "completedAt")
        try authenticatedBy.validateActive(at: completedAt)
        self.contractVersion = contractVersion
        self.requestID = requestID
        self.grantID = grantID
        self.reservationID = reservationID
        self.scope = scope
        self.mode = mode
        self.modelHash = modelHash
        self.fence = fence
        self.outcome = outcome
        self.outputBytes = outputBytes
        self.outputDigest = outputDigest
        self.usage = usage
        self.provenance = provenance
        self.completedAt = completedAt
        self.authenticatedBy = authenticatedBy
        self.errorCode = errorCode
    }

    public func validate(against request: AcceleratorExecutionRequest) throws {
        try AcceleratorValidation.version(contractVersion)
        guard request.requestID == requestID,
              request.grantID == grantID,
              request.reservationID == reservationID,
              request.scope == scope,
              request.mode == mode,
              request.modelHash == modelHash,
              request.fence == fence else {
            throw AcceleratorValidation.fail(.requestMismatch, "result")
        }
        guard completedAt >= request.requestedAt else {
            throw AcceleratorValidation.fail(
                .outOfOrderObservation,
                "completedAt"
            )
        }
        guard outputBytes <= request.outputLimitBytes else {
            throw AcceleratorValidation.fail(
                .outputLimitExceeded,
                "outputBytes"
            )
        }
        guard authenticatedBy == request.authentication else {
            throw AcceleratorValidation.fail(
                .grantMismatch,
                "authenticatedBy"
            )
        }
        if let usage {
            try AcceleratorValidation.version(usage.contractVersion)
            guard usage.budget.fits(in: request.budget),
                  usage.observedAt >= request.requestedAt,
                  usage.observedAt <= completedAt,
                  usage.authenticatedBy == request.authentication else {
                throw AcceleratorValidation.fail(.invalidUsage, "usage")
            }
        }
        if let provenance {
            try AcceleratorValidation.version(provenance.contractVersion)
            guard provenance.requestID == request.requestID,
                  provenance.mode == request.mode,
                  provenance.modelHash == request.modelHash,
                  provenance.recordedAt >= request.requestedAt,
                  provenance.recordedAt <= completedAt,
                  provenance.authenticatedBy == request.authentication else {
                throw AcceleratorValidation.fail(
                    .invalidProvenance,
                    "provenance"
                )
            }
        }
        if outcome == .succeeded {
            guard usage != nil, provenance != nil, errorCode == nil else {
                throw AcceleratorValidation.fail(
                    .invalidUsage,
                    "succeeded"
                )
            }
        }
    }

    public func validate(
        against request: AcceleratorExecutionRequest,
        inventory: AcceleratorInventorySnapshot
    ) throws {
        try validate(against: request)
        guard let provenance else {
            return
        }
        guard provenance.inventorySnapshotID == inventory.snapshotID,
              provenance.inventoryGeneration == inventory.observedGeneration,
              provenance.source == .hostNativeExecutionSelfTest,
              let evidence = inventory.evidence(for: request.mode),
              evidence.status == .available,
              evidence.source == .hostNativeExecutionSelfTest,
              evidence.observedGeneration == inventory.observedGeneration,
              let executionEvidence = evidence.executionEvidence,
              executionEvidence.mode == request.mode,
              executionEvidence.observedGeneration == inventory.observedGeneration,
              executionEvidence.provenanceDigest == evidence.evidenceDigest,
              provenance.evidenceDigest == evidence.evidenceDigest else {
            throw AcceleratorValidation.fail(.invalidProvenance, "provenance.evidenceDigest")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case requestID
        case grantID
        case reservationID
        case scope
        case mode
        case modelHash
        case fence
        case outcome
        case outputBytes
        case outputDigest
        case usage
        case provenance
        case completedAt
        case authenticatedBy
        case errorCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestID: container.decode(UUID.self, forKey: .requestID),
            grantID: container.decode(UUID.self, forKey: .grantID),
            reservationID: container.decode(UUID.self, forKey: .reservationID),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            mode: container.decode(
                AcceleratorExecutionMode.self,
                forKey: .mode
            ),
            modelHash: container.decode(
                AcceleratorDigest.self,
                forKey: .modelHash
            ),
            fence: container.decode(AcceleratorFence.self, forKey: .fence),
            outcome: container.decode(
                AcceleratorExecutionOutcome.self,
                forKey: .outcome
            ),
            outputBytes: container.decode(Int.self, forKey: .outputBytes),
            outputDigest: container.decodeIfPresent(
                AcceleratorDigest.self,
                forKey: .outputDigest
            ),
            usage: container.decodeIfPresent(
                AcceleratorMeasuredUsage.self,
                forKey: .usage
            ),
            provenance: container.decodeIfPresent(
                AcceleratorExecutionProvenance.self,
                forKey: .provenance
            ),
            completedAt: container.decode(Date.self, forKey: .completedAt),
            authenticatedBy: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .authenticatedBy
            ),
            errorCode: container.decodeIfPresent(
                AcceleratorErrorCode.self,
                forKey: .errorCode
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorCancellationState: String, Codable, CaseIterable, Equatable, Sendable {
    case requested
    case accepted
    case rejected
    case completed
}

public struct AcceleratorCancellationRecord:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let cancellationID: UUID
    public let requestID: UUID
    public let grantID: UUID
    public let reservationID: UUID
    public let scope: AcceleratorScope
    public let fence: AcceleratorFence
    public let actor: AcceleratorAuthenticationContext
    public let reason: String
    public let requestedAt: Date
    public let state: AcceleratorCancellationState
    public let effectiveAt: Date?

    public init(
        cancellationID: UUID,
        requestID: UUID,
        grantID: UUID,
        reservationID: UUID,
        scope: AcceleratorScope,
        fence: AcceleratorFence,
        actor: AcceleratorAuthenticationContext,
        reason: String,
        requestedAt: Date,
        state: AcceleratorCancellationState,
        effectiveAt: Date?,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(cancellationID, field: "cancellationID")
        try AcceleratorValidation.uuid(requestID, field: "requestID")
        try AcceleratorValidation.uuid(grantID, field: "grantID")
        try AcceleratorValidation.uuid(
            reservationID,
            field: "reservationID"
        )
        try AcceleratorValidation.scope(scope)
        try AcceleratorValidation.reason(reason)
        try AcceleratorValidation.date(requestedAt, field: "requestedAt")
        try actor.validateActive(at: requestedAt)
        if let effectiveAt {
            try AcceleratorValidation.date(effectiveAt, field: "effectiveAt")
            guard effectiveAt >= requestedAt else {
                throw AcceleratorValidation.fail(
                    .invalidCancellation,
                    "effectiveAt"
                )
            }
        }
        switch state {
        case .requested:
            guard effectiveAt == nil else {
                throw AcceleratorValidation.fail(
                    .invalidCancellation,
                    "effectiveAt"
                )
            }
        case .accepted, .completed:
            guard effectiveAt != nil else {
                throw AcceleratorValidation.fail(
                    .invalidCancellation,
                    "effectiveAt"
                )
            }
        case .rejected:
            break
        }
        self.contractVersion = contractVersion
        self.cancellationID = cancellationID
        self.requestID = requestID
        self.grantID = grantID
        self.reservationID = reservationID
        self.scope = scope
        self.fence = fence
        self.actor = actor
        self.reason = reason
        self.requestedAt = requestedAt
        self.state = state
        self.effectiveAt = effectiveAt
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case cancellationID
        case requestID
        case grantID
        case reservationID
        case scope
        case fence
        case actor
        case reason
        case requestedAt
        case state
        case effectiveAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cancellationID: container.decode(UUID.self, forKey: .cancellationID),
            requestID: container.decode(UUID.self, forKey: .requestID),
            grantID: container.decode(UUID.self, forKey: .grantID),
            reservationID: container.decode(
                UUID.self,
                forKey: .reservationID
            ),
            scope: container.decode(AcceleratorScope.self, forKey: .scope),
            fence: container.decode(AcceleratorFence.self, forKey: .fence),
            actor: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .actor
            ),
            reason: container.decode(String.self, forKey: .reason),
            requestedAt: container.decode(Date.self, forKey: .requestedAt),
            state: container.decode(
                AcceleratorCancellationState.self,
                forKey: .state
            ),
            effectiveAt: container.decodeIfPresent(
                Date.self,
                forKey: .effectiveAt
            ),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}

public enum AcceleratorRevocationTargetKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claim
    case grant
    case reservation
    case session
}

public struct AcceleratorRevocationRecord:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let contractVersion: Int
    public let revocationID: UUID
    public let targetKind: AcceleratorRevocationTargetKind
    public let targetIdentifier: String
    public let scope: AcceleratorScope?
    public let fence: AcceleratorFence?
    public let actor: AcceleratorAuthenticationContext
    public let reason: String
    public let evidenceDigest: AcceleratorDigest
    public let revokedAt: Date

    public init(
        revocationID: UUID,
        targetKind: AcceleratorRevocationTargetKind,
        targetIdentifier: String,
        scope: AcceleratorScope?,
        fence: AcceleratorFence?,
        actor: AcceleratorAuthenticationContext,
        reason: String,
        evidenceDigest: AcceleratorDigest,
        revokedAt: Date,
        contractVersion: Int = AcceleratorContract.currentVersion
    ) throws {
        try AcceleratorValidation.version(contractVersion)
        try AcceleratorValidation.uuid(revocationID, field: "revocationID")
        try AcceleratorValidation.identifier(
            targetIdentifier,
            field: "targetIdentifier"
        )
        try AcceleratorValidation.reason(reason)
        try AcceleratorValidation.date(revokedAt, field: "revokedAt")
        try actor.validateActive(at: revokedAt)
        if let scope {
            try AcceleratorValidation.scope(scope)
        }
        switch targetKind {
        case .claim:
            try Self.validateUUIDTargetIdentifier(targetIdentifier)
            guard scope != nil, fence == nil else {
                throw AcceleratorValidation.fail(
                    .invalidRevocation,
                    "claim-target"
                )
            }
        case .grant, .reservation:
            try Self.validateUUIDTargetIdentifier(targetIdentifier)
            guard scope != nil, fence != nil else {
                throw AcceleratorValidation.fail(
                    .invalidRevocation,
                    "fenced-target"
                )
            }
        case .session:
            guard scope == nil, fence == nil else {
                throw AcceleratorValidation.fail(
                    .invalidRevocation,
                    "session-target"
                )
            }
        }
        self.contractVersion = contractVersion
        self.revocationID = revocationID
        self.targetKind = targetKind
        self.targetIdentifier = targetIdentifier
        self.scope = scope
        self.fence = fence
        self.actor = actor
        self.reason = reason
        self.evidenceDigest = evidenceDigest
        self.revokedAt = revokedAt
    }

    private static func validateUUIDTargetIdentifier(_ value: String) throws {
        guard let targetUUID = UUID(uuidString: value),
              targetUUID.uuidString.lowercased() == value else {
            throw AcceleratorValidation.fail(
                .invalidIdentifier,
                "targetIdentifier"
            )
        }
        try AcceleratorValidation.uuid(targetUUID, field: "targetIdentifier")
    }

    private enum CodingKeys: String, CodingKey {
        case contractVersion
        case revocationID
        case targetKind
        case targetIdentifier
        case scope
        case fence
        case actor
        case reason
        case evidenceDigest
        case revokedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revocationID: container.decode(UUID.self, forKey: .revocationID),
            targetKind: container.decode(
                AcceleratorRevocationTargetKind.self,
                forKey: .targetKind
            ),
            targetIdentifier: container.decode(
                String.self,
                forKey: .targetIdentifier
            ),
            scope: container.decodeIfPresent(
                AcceleratorScope.self,
                forKey: .scope
            ),
            fence: container.decodeIfPresent(
                AcceleratorFence.self,
                forKey: .fence
            ),
            actor: container.decode(
                AcceleratorAuthenticationContext.self,
                forKey: .actor
            ),
            reason: container.decode(String.self, forKey: .reason),
            evidenceDigest: container.decode(
                AcceleratorDigest.self,
                forKey: .evidenceDigest
            ),
            revokedAt: container.decode(Date.self, forKey: .revokedAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }
}
