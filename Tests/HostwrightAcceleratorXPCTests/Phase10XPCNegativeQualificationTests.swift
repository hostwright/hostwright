import CryptoKit
import Foundation
import XCTest
import HostwrightAccelerator
@testable import HostwrightAcceleratorXPC

final class Phase10XPCNegativeQualificationTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let claimID = UUID(uuidString: "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a")!
    private let reservationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let grantID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let requestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let cancellationID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    private let revocationID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    func testIdentityPolicyRejectsRoleConfusionAndEntitlementSubstitution() throws {
        let daemon = try proof(
            identifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
            entitlements: AcceleratorXPCIdentityPolicy.daemonEntitlementProjection,
            character: "a"
        )
        XCTAssertNoThrow(try daemon.validate(as: .daemon))
        XCTAssertThrowsError(try daemon.validate(as: .service)) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .identifierMismatch)
        }

        let serviceWithoutSandbox = try proof(
            identifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
            entitlements: AcceleratorXPCIdentityPolicy.daemonEntitlementProjection,
            character: "b"
        )
        XCTAssertThrowsError(try serviceWithoutSandbox.validate(as: .service)) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .entitlementMismatch)
        }

        let client = try proof(
            identifier: "hostwright-control",
            entitlements: AcceleratorXPCIdentityPolicy.clientEntitlementProjection,
            character: "c"
        )
        XCTAssertNoThrow(try client.validate(as: .client))
        XCTAssertThrowsError(try client.validate(as: .daemon)) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .identifierMismatch)
        }

        XCTAssertThrowsError(
            try AcceleratorXPCCodeIdentityProof(
                teamIdentifier: "OTHERTEAM1",
                signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
                codeDirectoryHash: String(repeating: "d", count: 40),
                entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .invalidProof)
        }
        XCTAssertThrowsError(
            try AcceleratorXPCCodeIdentityProof(
                teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
                codeDirectoryHash: String(repeating: "A", count: 40),
                entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .codeDirectoryHashInvalid)
        }
    }

    func testClientValidationRejectsPeerProofAndResponseBindingMismatches() throws {
        let request = try makeInventoryRequest(requestID: requestID)
        let validResponse = try unavailableResponse(for: request)

        XCTAssertThrowsError(
            try AcceleratorXPCClient.validate(
                response: validResponse,
                for: request,
                liveServiceProof: try proof(
                    identifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
                    entitlements: AcceleratorXPCIdentityPolicy.daemonEntitlementProjection,
                    character: "a"
                )
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCClientError, .authenticationFailed)
        }

        let differentServiceProof = try proof(
            identifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
            entitlements: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection,
            character: "c"
        )
        XCTAssertThrowsError(
            try AcceleratorXPCClient.validate(
                response: validResponse,
                for: request,
                liveServiceProof: differentServiceProof
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCClientError, .invalidResponse)
        }

        let wrongRequestIDResponse = try AcceleratorXPCResponse(
            operation: request.operation,
            requestID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            status: .unavailable,
            idempotencyDigest: request.idempotencyDigest,
            serviceProof: validResponse.serviceProof,
            error: try AcceleratorXPCError(code: .backendUnavailable)
        )
        XCTAssertThrowsError(
            try AcceleratorXPCClient.validate(
                response: wrongRequestIDResponse,
                for: request,
                liveServiceProof: validResponse.serviceProof
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCClientError, .invalidResponse)
        }
    }

    func testRegistryAbandonmentAndConnectionInvalidationDoNotAuthorizeReplayOrCancel() throws {
        let registry = try AcceleratorXPCRequestRegistry(maxConcurrent: 1)
        let first = try makeInventoryRequest(requestID: requestID)
        XCTAssertEqual(try registry.begin(first), .admitted)
        XCTAssertThrowsError(try registry.begin(first)) { error in
            XCTAssertEqual(error as? AcceleratorXPCRequestRegistryError, .idempotencyConflict)
        }

        registry.connectionInvalidated()
        XCTAssertEqual(registry.activeCount, 0)
        registry.abandon(first)
        XCTAssertThrowsError(try registry.begin(first)) { error in
            XCTAssertEqual(error as? AcceleratorXPCRequestRegistryError, .replayHistoryUnavailable)
        }

        let second = try makeInventoryRequest(
            requestID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
            observedAt: now.addingTimeInterval(1)
        )
        XCTAssertNotEqual(first.idempotencyDigest, second.idempotencyDigest)
        XCTAssertEqual(try registry.begin(second), .admitted)
        registry.finish(second, response: try unavailableResponse(for: second))
        guard case .replayed(let replay) = try registry.begin(second) else {
            return XCTFail("a completed request must be replayable by exact digest")
        }
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.idempotencyDigest, second.idempotencyDigest)
    }

    func testRegistryRevocationUsesCanonicalExactTargetsAndSurvivesTransportLoss() throws {
        let payload = try makeExecutionPayload()
        let registry = try AcceleratorXPCRequestRegistry()
        XCTAssertFalse(registry.isRevoked(payload))

        registry.connectionInvalidated()
        XCTAssertFalse(registry.isRevoked(payload))

        let uppercasedTarget = payload.claim.claimID.uuidString
        XCTAssertThrowsError(
            try makeClaimRevocationPayload(for: payload, targetIdentifier: uppercasedTarget)
        ) { error in
            XCTAssertEqual(error as? AcceleratorValidationError, .init(code: .invalidIdentifier, field: "targetIdentifier"))
        }

        let revokePayload = try makeClaimRevocationPayload(for: payload)
        try registry.revoke(payload: revokePayload)
        XCTAssertTrue(registry.isRevoked(payload))
        try registry.revoke(payload: revokePayload)
        registry.connectionInvalidated()
        XCTAssertTrue(registry.isRevoked(payload))

        let unrelated = try makeExecutionPayload(
            requestID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
            claimID: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!,
            reservationID: UUID(uuidString: "12121212-1212-4121-8121-121212121212")!,
            grantID: UUID(uuidString: "13131313-1313-4131-8131-131313131313")!
        )
        XCTAssertFalse(registry.isRevoked(unrelated))
    }

    func testCancelAndRevokePayloadsRejectCrossBindingAndWrongActorInputs() throws {
        let fixture = try makeExecutionFixture()
        let wrongRequestCancellation = try AcceleratorCancellationRecord(
            cancellationID: cancellationID,
            requestID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
            grantID: fixture.grant.grantID,
            reservationID: fixture.reservation.reservationID,
            scope: fixture.reservation.scope,
            fence: fixture.reservation.fence,
            actor: fixture.authentication,
            reason: "operator-request",
            requestedAt: now.addingTimeInterval(3),
            state: .requested,
            effectiveAt: nil
        )
        XCTAssertThrowsError(
            try AcceleratorXPCCancelPayload(
                executionRequest: fixture.request,
                cancellation: wrongRequestCancellation,
                claim: fixture.claim,
                grant: fixture.grant,
                reservation: fixture.reservation,
                inventory: fixture.inventory,
                observedAt: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .requestMismatch)
        }

        let otherActor = try makeAuthentication(subjectID: "other-subject")
        let wrongActorCancellation = try AcceleratorCancellationRecord(
            cancellationID: UUID(uuidString: "abababab-abab-4bab-8bab-abababababab")!,
            requestID: fixture.request.requestID,
            grantID: fixture.grant.grantID,
            reservationID: fixture.reservation.reservationID,
            scope: fixture.reservation.scope,
            fence: fixture.reservation.fence,
            actor: otherActor,
            reason: "operator-request",
            requestedAt: now.addingTimeInterval(3),
            state: .requested,
            effectiveAt: nil
        )
        XCTAssertThrowsError(
            try AcceleratorXPCCancelPayload(
                executionRequest: fixture.request,
                cancellation: wrongActorCancellation,
                claim: fixture.claim,
                grant: fixture.grant,
                reservation: fixture.reservation,
                inventory: fixture.inventory,
                observedAt: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .authenticationFailed)
        }

        let sessionRevocation = try AcceleratorRevocationRecord(
            revocationID: revocationID,
            targetKind: .session,
            targetIdentifier: fixture.authentication.sessionID,
            scope: nil,
            fence: nil,
            actor: fixture.authentication,
            reason: "operator-request",
            evidenceDigest: try digest("e"),
            revokedAt: now.addingTimeInterval(3)
        )
        XCTAssertThrowsError(
            try AcceleratorXPCRevokePayload(
                revocation: sessionRevocation,
                claim: fixture.claim,
                observedAt: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .requestMismatch)
        }

        let missingReservation = try AcceleratorRevocationRecord(
            revocationID: UUID(uuidString: "cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd")!,
            targetKind: .reservation,
            targetIdentifier: fixture.reservation.reservationID.uuidString.lowercased(),
            scope: fixture.reservation.scope,
            fence: fixture.reservation.fence,
            actor: fixture.authentication,
            reason: "operator-request",
            evidenceDigest: try digest("f"),
            revokedAt: now.addingTimeInterval(3)
        )
        XCTAssertThrowsError(
            try AcceleratorXPCRevokePayload(
                revocation: missingReservation,
                claim: fixture.claim,
                grant: fixture.grant,
                observedAt: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .requestMismatch)
        }

        let wrongActorRevocation = try AcceleratorRevocationRecord(
            revocationID: UUID(uuidString: "dededede-dede-4ede-8ede-dededededede")!,
            targetKind: .claim,
            targetIdentifier: fixture.claim.claimID.uuidString.lowercased(),
            scope: fixture.claim.scope,
            fence: nil,
            actor: otherActor,
            reason: "operator-request",
            evidenceDigest: try digest("7"),
            revokedAt: now.addingTimeInterval(3)
        )
        XCTAssertThrowsError(
            try AcceleratorXPCRevokePayload(
                revocation: wrongActorRevocation,
                claim: fixture.claim,
                observedAt: now.addingTimeInterval(3)
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .authenticationFailed)
        }

        let validRevoke = try makeClaimRevocationPayload(for: fixture.payload)
        var hostileObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(validRevoke),
                options: []
            ) as? [String: Any]
        )
        var hostileRevocation = try XCTUnwrap(
            hostileObject["revocation"] as? [String: Any]
        )
        var hostileActor = try XCTUnwrap(
            hostileRevocation["actor"] as? [String: Any]
        )
        hostileActor["subjectID"] = otherActor.subjectID
        hostileRevocation["actor"] = hostileActor
        hostileObject["revocation"] = hostileRevocation
        let hostileData = try JSONSerialization.data(
            withJSONObject: hostileObject,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                AcceleratorXPCRevokePayload.self,
                from: hostileData
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .authenticationFailed)
        }
    }

    func testStatusTruthUsesUnavailableOrUnsupportedUntilEvidenceExists() throws {
        let unavailable = try AcceleratorXPCStatusSnapshot(
            hostID: hostID,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 1,
            observedAt: now,
            availability: .unavailable
        )
        let unsupported = try AcceleratorXPCStatusSnapshot(
            hostID: hostID,
            inventorySnapshotID: snapshotID,
            inventoryGeneration: 1,
            observedAt: now,
            availability: .unsupported
        )
        XCTAssertNotEqual(unavailable.availability, .available)
        XCTAssertNotEqual(unsupported.availability, .available)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AcceleratorXPCStatusSnapshot.self,
                from: JSONEncoder().encode(unavailable)
            ),
            unavailable
        )

        let request = try makeInventoryRequest(requestID: requestID)
        let response = try unavailableResponse(for: request)
        XCTAssertEqual(response.status, .unavailable)
        XCTAssertEqual(response.error?.code, .backendUnavailable)
        XCTAssertNil(response.payload)
    }

    private func makeInventoryRequest(
        requestID: UUID,
        observedAt: Date = Date(timeIntervalSince1970: 1_754_000_000)
    ) throws -> AcceleratorXPCRequest {
        try AcceleratorXPCRequest(
            operation: .inventory,
            requestID: requestID,
            timeoutMilliseconds: 1_000,
            payload: .inventory(
                try AcceleratorXPCInventoryQuery(
                    hostID: hostID,
                    requester: try makeAuthentication(),
                    observedAt: observedAt
                )
            )
        )
    }

    private func unavailableResponse(
        for request: AcceleratorXPCRequest
    ) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: request.operation,
            requestID: request.requestID,
            status: .unavailable,
            idempotencyDigest: request.idempotencyDigest,
            serviceProof: try serviceProof,
            error: try AcceleratorXPCError(code: .backendUnavailable)
        )
    }

    private func makeExecutionPayload(
        requestID: UUID? = nil,
        claimID: UUID? = nil,
        reservationID: UUID? = nil,
        grantID: UUID? = nil
    ) throws -> AcceleratorXPCExecutePayload {
        try makeExecutionFixture(
            requestID: requestID ?? self.requestID,
            claimID: claimID ?? self.claimID,
            reservationID: reservationID ?? self.reservationID,
            grantID: grantID ?? self.grantID
        ).payload
    }

    private func makeClaimRevocationPayload(
        for payload: AcceleratorXPCExecutePayload,
        targetIdentifier: String? = nil
    ) throws -> AcceleratorXPCRevokePayload {
        let revocation = try AcceleratorRevocationRecord(
            revocationID: revocationID,
            targetKind: .claim,
            targetIdentifier: targetIdentifier ?? payload.claim.claimID.uuidString.lowercased(),
            scope: payload.claim.scope,
            fence: nil,
            actor: payload.claim.issuer,
            reason: "operator-request",
            evidenceDigest: try digest("e"),
            revokedAt: now.addingTimeInterval(3)
        )
        return try AcceleratorXPCRevokePayload(
            revocation: revocation,
            claim: payload.claim,
            observedAt: now.addingTimeInterval(3)
        )
    }

    private func makeExecutionFixture(
        requestID: UUID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
        claimID: UUID = UUID(uuidString: "6a6a6a6a-6a6a-4a6a-8a6a-6a6a6a6a6a6a")!,
        reservationID: UUID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!,
        grantID: UUID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    ) throws -> ExecutionFixture {
        let authentication = try makeAuthentication()
        let inventory = try makeInventory()
        let modelHash = try digest("d")
        let quota = try AcceleratorQuota(
            budget: try AcceleratorBudgetVector(
                memoryBytes: 4 * 1024 * 1024,
                computeUnits: 500,
                concurrencyUnits: 2
            ),
            maxInputBytes: 1_024,
            maxOutputBytes: 1_024,
            maxTimeoutMilliseconds: 10_000
        )
        let claim = try AcceleratorClaim(
            claimID: claimID,
            scope: .project(projectID: projectID),
            allowedModes: [.metal],
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            issuer: authentication,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let reservation = try AcceleratorReservation(
            reservationID: reservationID,
            claimID: claim.claimID,
            scope: .workload(projectID: projectID, workloadID: workloadID),
            mode: .metal,
            modelHash: modelHash,
            budget: try AcceleratorBudgetVector(
                memoryBytes: 2 * 1024 * 1024,
                computeUnits: 200,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: try AcceleratorFence(nodeEpoch: 4, reservationSequence: 9),
            owner: authentication,
            createdAt: now,
            expiresAt: now.addingTimeInterval(120)
        )
        let committed = try AcceleratorReservationStateMachine().transition(
            reservation: reservation,
            request: AcceleratorReservationTransitionRequest(
                transition: .commit,
                reservationID: reservation.reservationID,
                scope: reservation.scope,
                fence: reservation.fence,
                actor: authentication,
                observedAt: now.addingTimeInterval(1)
            )
        )
        let grant = try AcceleratorGrant(
            grantID: grantID,
            claimID: claim.claimID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            granteeSubjectID: authentication.subjectID,
            mode: .metal,
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: committed.fence,
            issuer: authentication,
            issuedAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(120)
        )
        let input = Data([0x01])
        let request = try AcceleratorExecutionRequest(
            requestID: requestID,
            grantID: grant.grantID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            mode: .metal,
            modelHash: modelHash,
            inputDigest: try sha256(input),
            inputBytes: input.count,
            outputLimitBytes: 1_024,
            timeoutMilliseconds: 1_000,
            budget: try AcceleratorBudgetVector(
                memoryBytes: 1,
                computeUnits: 1,
                concurrencyUnits: 1
            ),
            fence: committed.fence,
            authentication: authentication,
            requestedAt: now.addingTimeInterval(2)
        )
        return ExecutionFixture(
            payload: try AcceleratorXPCExecutePayload(
                request: request,
                claim: claim,
                grant: grant,
                reservation: committed,
                inventory: inventory,
                inputPayload: input,
                observedAt: now.addingTimeInterval(2)
            ),
            request: request,
            claim: claim,
            grant: grant,
            reservation: committed,
            inventory: inventory,
            authentication: authentication
        )
    }

    private func makeInventory() throws -> AcceleratorInventorySnapshot {
        let evidence = try digest("a")
        return try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 7,
            modeEvidence: [
                try AcceleratorModeEvidence(
                    mode: .coreML,
                    status: .unavailable,
                    evidenceDigest: evidence,
                    source: .contractBoundary,
                    observedGeneration: 7,
                    reasonCode: .evidenceUnavailable
                ),
                try AcceleratorModeEvidence(
                    mode: .linuxGuestANEPassthrough,
                    status: .blocked,
                    evidenceDigest: evidence,
                    source: .contractBoundary,
                    observedGeneration: 7,
                    reasonCode: .linuxGuestPassthroughBlocked
                ),
                try AcceleratorModeEvidence(
                    mode: .linuxGuestGPUPassthrough,
                    status: .blocked,
                    evidenceDigest: evidence,
                    source: .contractBoundary,
                    observedGeneration: 7,
                    reasonCode: .linuxGuestPassthroughBlocked
                ),
                // Positive transport fixture only; its synthetic execution
                // proof is contract input, not a G15 capability claim.
                try AcceleratorModeEvidence(
                    mode: .metal,
                    status: .available,
                    evidenceDigest: evidence,
                    source: .hostNativeExecutionSelfTest,
                    observedGeneration: 7,
                    executionEvidence: try AcceleratorHostNativeExecutionEvidence(
                        mode: .metal,
                        backendIdentifier: "metal",
                        frameworkIdentifier: "host-native",
                        operatingSystem: "macos",
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7,
                        observedAt: now,
                        completedAt: now.addingTimeInterval(1)
                    )
                )
            ],
            budgets: [
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .compute,
                    amount: 10_000,
                    unit: .computeUnits,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .compute,
                        amount: 10_000,
                        unit: .computeUnits,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                ),
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .concurrency,
                    amount: 8,
                    unit: .concurrentExecutions,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .concurrency,
                        amount: 8,
                        unit: .concurrentExecutions,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                ),
                try AcceleratorMeasuredBudget(
                    mode: .metal,
                    kind: .memory,
                    amount: 64 * 1024 * 1024,
                    unit: .bytes,
                    source: .hostNativeModeMeasurement,
                    observedGeneration: 7,
                    measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                        executionDigest: evidence,
                        provenanceDigest: evidence,
                        observedGeneration: 7
                    ),
                    measurementEvidenceDigest: try AcceleratorMeasuredBudget.measurementEvidenceDigest(
                        mode: .metal,
                        kind: .memory,
                        amount: 64 * 1024 * 1024,
                        unit: .bytes,
                        observedGeneration: 7,
                        measurementEvidence: try AcceleratorBudgetMeasurementEvidence(
                            executionDigest: evidence,
                            provenanceDigest: evidence,
                            observedGeneration: 7
                        )
                    )
                )
            ]
        )
    }

    private func makeAuthentication(
        subjectID: String = "subject-owner",
        sessionID: String = "session-1"
    ) throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: subjectID,
            sessionID: sessionID,
            authenticationDigest: try digest("c"),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func proof(
        identifier: String,
        entitlements: [String: Bool],
        character: Character
    ) throws -> AcceleratorXPCCodeIdentityProof {
        try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: identifier,
            codeDirectoryHash: String(repeating: character, count: 40),
            entitlementProjection: entitlements
        )
    }

    private var serviceProof: AcceleratorXPCCodeIdentityProof {
        get throws {
            try proof(
                identifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
                entitlements: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection,
                character: "b"
            )
        }
    }

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }

    private func sha256(_ data: Data) throws -> AcceleratorDigest {
        try AcceleratorDigest(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}

private struct ExecutionFixture: Sendable {
    let payload: AcceleratorXPCExecutePayload
    let request: AcceleratorExecutionRequest
    let claim: AcceleratorClaim
    let grant: AcceleratorGrant
    let reservation: AcceleratorReservation
    let inventory: AcceleratorInventorySnapshot
    let authentication: AcceleratorAuthenticationContext
}
