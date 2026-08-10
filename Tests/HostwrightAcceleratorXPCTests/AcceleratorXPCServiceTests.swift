import Foundation
import XCTest
@testable import HostwrightAccelerator
@testable import HostwrightAcceleratorXPC
import HostwrightCore

final class AcceleratorXPCServiceTests: XCTestCase {
    func testMaximumRawInputRoundTripsThroughEncodedXPCEnvelope() throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            inputPayload: Data(repeating: 0xA5, count: AcceleratorLimits.maxInputBytes)
        )
        let encoded = try AcceleratorXPCMessageCodec.encodeRequest(fixture.executeRequest)
        let decoded = try AcceleratorXPCMessageCodec.decodeRequest(encoded)
        XCTAssertEqual(decoded, fixture.executeRequest)
        guard case .execute(let payload) = decoded.payload else {
            return XCTFail("maximum input did not decode as an execute payload")
        }
        XCTAssertEqual(payload.inputPayload.count, AcceleratorLimits.maxInputBytes)
    }

    func testExplicitCancelCooperativelyStopsSuspendedBackend() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let backend = SuspendedBackend(modelArtifact: fixture.modelArtifact)
        let service = try makeService(backend: backend)
        let peer = try daemonProof
        let request = fixture.executeRequest
        let execution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(request, peer: peer)
        }
        let started = await backend.waitUntilStarted(count: 1)
        XCTAssertTrue(started)

        let acknowledgement = try await service.handle(
            fixture.cancelRequest,
            peer: daemonProof
        )
        XCTAssertEqual(acknowledgement.status, .completed)
        let acknowledgementOperation: AcceleratorXPCOperation? = acknowledgement.payload.flatMap { payload in
            if case .acknowledgement(let value) = payload { return value.operation }
            return nil
        }
        XCTAssertEqual(acknowledgementOperation, AcceleratorXPCOperation.cancel)

        let response = try await execution.value
        XCTAssertEqual(response.status, .cancelled)
        let cancelled = await backend.waitUntilCancelled(fixture.requestID)
        XCTAssertTrue(cancelled)
    }

    func testRevokeCooperativelyStopsOnlyMatchingBackendWork() async throws {
        let first = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            claimID: UUID(uuidString: "66666666-6666-4666-8666-666666666662")!,
            reservationID: UUID(uuidString: "77777777-7777-4777-8777-777777777773")!,
            grantID: UUID(uuidString: "88888888-8888-4888-8888-888888888884")!
        )
        let backend = SuspendedBackend(modelArtifact: first.modelArtifact)
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let peer = try daemonProof
        let firstRequest = first.executeRequest
        let secondRequest = second.executeRequest
        let firstExecution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(firstRequest, peer: peer)
        }
        let secondExecution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(secondRequest, peer: peer)
        }
        let started = await backend.waitUntilStarted(count: 2)
        XCTAssertTrue(started)
        service.registry.connectionInvalidated()
        let firstCancelledBeforeRevoke = await backend.wasCancelled(first.requestID)
        let secondCancelledBeforeRevoke = await backend.wasCancelled(second.requestID)
        XCTAssertFalse(firstCancelledBeforeRevoke)
        XCTAssertFalse(secondCancelledBeforeRevoke)

        let acknowledgement = try await service.handle(
            first.revokeRequest,
            peer: daemonProof
        )
        XCTAssertEqual(acknowledgement.status, .completed)
        let firstResponse = try await firstExecution.value
        XCTAssertEqual(firstResponse.status, .revoked)
        let firstCancelledAfterRevoke = await backend.waitUntilCancelled(first.requestID)
        XCTAssertTrue(firstCancelledAfterRevoke)
        XCTAssertFalse(secondExecution.isCancelled)
        let unrelatedCancelled = await backend.wasCancelled(second.requestID)
        XCTAssertFalse(unrelatedCancelled)

        let secondAcknowledgement = try await service.handle(
            second.cancelRequest,
            peer: daemonProof
        )
        XCTAssertEqual(secondAcknowledgement.status, .completed)
        let secondResponse = try await secondExecution.value
        XCTAssertEqual(secondResponse.status, .cancelled)
    }

    func testPreCancelOnlyMatchesTheFullFutureExecutionBinding() async throws {
        let first = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            claimID: UUID(uuidString: "66666666-6666-4666-8666-666666666662")!,
            reservationID: UUID(uuidString: "77777777-7777-4777-8777-777777777773")!,
            grantID: UUID(uuidString: "88888888-8888-4888-8888-888888888884")!
        )
        let registry = try AcceleratorXPCRequestRegistry()
        let firstCancelled = CancellationFlag()
        let secondCancelled = CancellationFlag()

        try registry.cancel(binding: first.binding, cancellationID: first.cancellationID)
        registry.registerExecution(
            binding: second.binding,
            cancellation: { Task { await secondCancelled.set() } }
        )
        let secondWasCancelled = await secondCancelled.isSet()
        XCTAssertFalse(secondWasCancelled)
        registry.registerExecution(
            binding: first.binding,
            cancellation: { Task { await firstCancelled.set() } }
        )
        let firstWasCancelled = await firstCancelled.waitUntilSet()
        XCTAssertTrue(firstWasCancelled)
    }

    func testCrossBoundCancellationAndActorMismatchFailBeforeRegistryMutation() throws {
        let first = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            claimID: UUID(uuidString: "66666666-6666-4666-8666-666666666662")!,
            reservationID: UUID(uuidString: "77777777-7777-4777-8777-777777777773")!,
            grantID: UUID(uuidString: "88888888-8888-4888-8888-888888888884")!
        )
        let firstCancel = try XCTUnwrap(cancelPayload(from: first.cancelRequest))
        let secondExecute = try XCTUnwrap(executePayload(from: second.executeRequest))
        XCTAssertThrowsError(
            try AcceleratorXPCCancelPayload(
                executionRequest: firstCancel.executionRequest,
                cancellation: firstCancel.cancellation,
                claim: secondExecute.claim,
                grant: secondExecute.grant,
                reservation: secondExecute.reservation,
                inventory: secondExecute.inventory,
                observedAt: firstCancel.observedAt
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .requestMismatch)
        }

        let otherActor = try makeAuthentication(subjectID: "other-subject")
        XCTAssertThrowsError(
            try makeFixture(
                requestID: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!,
                cancellationID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
                cancellationActor: otherActor
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .authenticationFailed)
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.field, "actor")
        }

        let sameSubjectDifferentAuthentication = try makeAuthentication(
            subjectID: "subject-owner",
            sessionID: "session-2",
            credentialID: "credential-2",
            digestCharacter: "d"
        )
        XCTAssertThrowsError(
            try makeFixture(
                requestID: UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")!,
                cancellationID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                cancellationActor: sameSubjectDifferentAuthentication
            )
        ) { error in
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.code, .authenticationFailed)
            XCTAssertEqual((error as? AcceleratorXPCValidationError)?.field, "actor")
        }
    }

    func testTimeoutCancelsBackendWithoutFabricatingAnExecutionResult() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            timeoutMilliseconds: 25
        )
        let backend = SuspendedBackend(modelArtifact: fixture.modelArtifact)
        let service = try makeService(backend: backend)
        let response = try await service.handle(fixture.executeRequest, peer: daemonProof)
        XCTAssertEqual(response.status, .timedOut)
        XCTAssertEqual(response.error?.code, .timeout)
        let cancelled = await backend.waitUntilCancelled(fixture.requestID)
        XCTAssertTrue(cancelled)
        XCTAssertNil(response.payload)
    }

    func testAggregateBudgetChargeRejectsASecondRequestInTheSameLineage() async throws {
        let first = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        )
        let backend = SuspendedBackend(modelArtifact: first.modelArtifact)
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let peer = try daemonProof
        let firstRequest = first.executeRequest
        let firstExecution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(firstRequest, peer: peer)
        }
        let firstStarted = await backend.waitUntilStarted(count: 1)
        XCTAssertTrue(firstStarted)

        do {
            _ = try await service.handle(second.executeRequest, peer: peer)
            XCTFail("the second request must not overcommit the shared budget")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(
                error,
                .registry(.budgetLimitExceeded)
            )
        }

        _ = try await service.handle(first.cancelRequest, peer: peer)
        let firstResponse = try await firstExecution.value
        XCTAssertEqual(firstResponse.status, .cancelled)
        XCTAssertEqual(service.registry.activeCount, 0)
    }

    func testAggregateBudgetChargeIsIsolatedByScope() async throws {
        let first = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            projectID: projectID,
            workloadID: workloadID
        )
        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            projectID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            workloadID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        )
        let backend = SuspendedBackend(modelArtifact: first.modelArtifact)
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let peer = try daemonProof
        let firstRequest = first.executeRequest
        let secondRequest = second.executeRequest
        let firstExecution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(firstRequest, peer: peer)
        }
        let secondExecution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(secondRequest, peer: peer)
        }
        let bothStarted = await backend.waitUntilStarted(count: 2)
        XCTAssertTrue(bothStarted)

        _ = try await service.handle(first.cancelRequest, peer: peer)
        _ = try await service.handle(second.cancelRequest, peer: peer)
        let firstResponse = try await firstExecution.value
        let secondResponse = try await secondExecution.value
        XCTAssertEqual(firstResponse.status, .cancelled)
        XCTAssertEqual(secondResponse.status, .cancelled)
        XCTAssertEqual(service.registry.activeCount, 0)
    }

    func testNonCooperativeBackendRetainsBudgetUntilItActuallyTerminates() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let backend = NonCooperativeBackend(modelArtifact: fixture.modelArtifact)
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let peer = try daemonProof
        let executeRequest = fixture.executeRequest
        let execution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(executeRequest, peer: peer)
        }
        let started = await backend.waitUntilStarted()
        XCTAssertTrue(started)

        _ = try await service.handle(fixture.cancelRequest, peer: peer)
        XCTAssertEqual(service.registry.activeCount, 1)

        let replay = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(executeRequest, peer: peer)
        }
        do {
            _ = try await replay.value
            XCTFail("an active request must not be replayed before termination")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.idempotencyConflict))
        }

        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        )
        do {
            _ = try await service.handle(second.executeRequest, peer: peer)
            XCTFail("budget must remain charged while the backend is still suspended")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.budgetLimitExceeded))
        }

        await backend.release()
        let response = try await execution.value
        XCTAssertEqual(response.status, .cancelled)
        XCTAssertEqual(service.registry.activeCount, 0)
    }

    func testNonCooperativeBackendTimeoutReturnsAtDeadlineAndRetainsChargeUntilTermination() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            timeoutMilliseconds: 25
        )
        let backend = NonCooperativeBackend(modelArtifact: fixture.modelArtifact)
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let peer = try daemonProof
        let request = fixture.executeRequest
        let execution = Task<AcceleratorXPCResponse, Error> {
            try await service.handle(request, peer: peer)
        }
        let started = await backend.waitUntilStarted()
        XCTAssertTrue(started)

        let response = try await execution.value
        XCTAssertEqual(response.status, .timedOut)
        XCTAssertEqual(response.error?.code, .timeout)
        XCTAssertEqual(service.registry.activeCount, 1)

        let second = try makeFixture(
            requestID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!,
            cancellationID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        )
        do {
            _ = try await service.handle(second.executeRequest, peer: daemonProof)
            XCTFail("the second request must not overcommit retained timeout charge")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.budgetLimitExceeded))
        }

        await backend.release()
        for _ in 0..<100 where service.registry.activeCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(service.registry.activeCount, 0)
        let replay = try await service.handle(request, peer: peer)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.status, .timedOut)
    }

    func testSupervisedWorkerKillsNonCooperativeProcessBeforeReleasingCharge() async throws {
        let executablePath = "/bin/sleep"
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw XCTSkip("the platform sleep executable is unavailable")
        }
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            timeoutMilliseconds: 25
        )
        let executable = try SecureExecutableResolver.verify(
            path: executablePath,
            ownershipPolicy: .rootOrCurrentUser
        )
        let backend = try AcceleratorXPCProcessBackend(
            workerExecutable: executable,
            workerArguments: ["30"],
            artifact: fixture.modelArtifact
        )
        let service = try makeService(backend: backend, maxConcurrent: 2)
        let started = DispatchTime.now().uptimeNanoseconds
        let response = try await service.handle(
            fixture.executeRequest,
            peer: daemonProof
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - started

        XCTAssertEqual(response.status, .timedOut)
        XCTAssertEqual(response.error?.code, .timeout)
        XCTAssertLessThan(elapsed, 2_000_000_000)
        XCTAssertEqual(service.registry.activeCount, 1)

        for _ in 0..<400 where service.registry.activeCount != 0 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(service.registry.activeCount, 0)
        let replay = try await service.handle(
            fixture.executeRequest,
            peer: daemonProof
        )
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.status, .timedOut)
    }

    func testUnobservedWorkerCleanupRetainsAuthorityAndRejectsReplay() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let backend = UnobservedTerminationBackend(modelArtifact: fixture.modelArtifact)
        let service = try makeService(backend: backend)

        let response = try await service.handle(
            fixture.executeRequest,
            peer: daemonProof
        )
        XCTAssertEqual(response.status, .unavailable)
        XCTAssertEqual(response.error?.code, .serviceUnavailable)
        XCTAssertTrue(service.registry.executionIsRetained(fixture.executeRequest))
        XCTAssertEqual(service.registry.activeCount, 1)

        do {
            _ = try await service.handle(fixture.executeRequest, peer: daemonProof)
            XCTFail("replay must remain blocked while worker termination is unproven")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.idempotencyConflict))
        }
    }

    func testExecutionProvenanceMustMatchTheCurrentSelfTestEvidence() async throws {
        let fixture = try makeFixture(
            requestID: UUID(uuidString: "99999999-9999-4999-8999-999999999999")!,
            cancellationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let evidenceDigest = try digest("a")
        let validBackend = EvidenceBackend(
            modelArtifact: fixture.modelArtifact,
            provenanceDigest: evidenceDigest,
            source: .hostNativeExecutionSelfTest
        )
        let validService = try makeService(backend: validBackend)
        let validResponse = try await validService.handle(
            fixture.executeRequest,
            peer: daemonProof
        )
        XCTAssertEqual(validResponse.status, .completed)

        let mismatchedBackend = EvidenceBackend(
            modelArtifact: fixture.modelArtifact,
            provenanceDigest: try digest("b"),
            source: .hostNativeExecutionSelfTest
        )
        let mismatchedService = try makeService(backend: mismatchedBackend)
        let mismatchedResponse = try await mismatchedService.handle(
            fixture.executeRequest,
            peer: daemonProof
        )
        XCTAssertEqual(mismatchedResponse.status, .rejected)
        XCTAssertEqual(mismatchedResponse.error?.code, .invalidResponse)
    }

    private func makeService(
        backend: (any AcceleratorXPCBackend)?,
        maxConcurrent: Int = 1
    ) throws -> AcceleratorXPCService {
        try AcceleratorXPCService(
            backend: backend,
            maxConcurrent: maxConcurrent,
            identityInspector: ServiceIdentityInspector(proof: serviceProof)
        )
    }

    private func makeFixture(
        requestID: UUID,
        cancellationID: UUID,
        claimID: UUID? = nil,
        reservationID: UUID? = nil,
        grantID: UUID? = nil,
        projectID: UUID? = nil,
        workloadID: UUID? = nil,
        inputPayload: Data = Data([0x01]),
        cancellationActor: AcceleratorAuthenticationContext? = nil,
        timeoutMilliseconds: Int = 5_000
    ) throws -> ExecutionFixture {
        let context = try authentication
        let actor = cancellationActor ?? context
        let fixtureClaimID = claimID ?? self.claimID
        let fixtureReservationID = reservationID ?? self.reservationID
        let fixtureGrantID = grantID ?? self.grantID
        let fixtureProjectID = projectID ?? self.projectID
        let fixtureWorkloadID = workloadID ?? self.workloadID
        let inventory = try makeInventory()
        let modelBytes = Data([0x4D, 0x4C, 0x58])
        let modelHash = try AcceleratorXPCDigest.sha256(modelBytes)
        let modelArtifact = try AcceleratorXPCModelArtifact(
            modelHash: modelHash,
            bytes: modelBytes
        )
        let quota = try AcceleratorQuota(
            budget: AcceleratorBudgetVector(
                memoryBytes: 4 * 1024 * 1024,
                computeUnits: 500,
                concurrencyUnits: 2
            ),
            maxInputBytes: max(4 * 1024, inputPayload.count),
            maxOutputBytes: 8 * 1024,
            maxTimeoutMilliseconds: 10_000
        )
        let claim = try AcceleratorClaim(
            claimID: fixtureClaimID,
            scope: .project(projectID: fixtureProjectID),
            allowedModes: [.metal],
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            issuer: context,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
        let reservation = try AcceleratorReservation(
            reservationID: fixtureReservationID,
            claimID: claim.claimID,
            scope: .workload(projectID: fixtureProjectID, workloadID: fixtureWorkloadID),
            mode: .metal,
            modelHash: modelHash,
            budget: AcceleratorBudgetVector(
                memoryBytes: 2 * 1024 * 1024,
                computeUnits: 200,
                concurrencyUnits: 1
            ),
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: try AcceleratorFence(nodeEpoch: 4, reservationSequence: 9),
            owner: context,
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
                actor: context,
                observedAt: now.addingTimeInterval(1)
            )
        )
        let grant = try AcceleratorGrant(
            grantID: fixtureGrantID,
            claimID: claim.claimID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            granteeSubjectID: context.subjectID,
            mode: .metal,
            modelHash: modelHash,
            quota: quota,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            fence: committed.fence,
            issuer: context,
            issuedAt: now.addingTimeInterval(1),
            expiresAt: now.addingTimeInterval(120)
        )
        let input = inputPayload
        let request = try AcceleratorExecutionRequest(
            requestID: requestID,
            grantID: grant.grantID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            mode: .metal,
            modelHash: modelHash,
            inputDigest: try AcceleratorXPCDigest.sha256(input),
            inputBytes: input.count,
            outputLimitBytes: 4 * 1024,
            timeoutMilliseconds: timeoutMilliseconds,
            budget: AcceleratorBudgetVector(
                memoryBytes: 1 * 1024 * 1024,
                computeUnits: 100,
                concurrencyUnits: 1
            ),
            fence: committed.fence,
            authentication: context,
            requestedAt: now.addingTimeInterval(2)
        )
        let executePayload = try AcceleratorXPCExecutePayload(
            request: request,
            claim: claim,
            grant: grant,
            reservation: committed,
            inventory: inventory,
            inputPayload: input,
            observedAt: now.addingTimeInterval(2)
        )
        let executeRequest = try AcceleratorXPCRequest(
            operation: .execute,
            requestID: requestID,
            timeoutMilliseconds: timeoutMilliseconds,
            payload: .execute(executePayload)
        )
        let cancellation = try AcceleratorCancellationRecord(
            cancellationID: cancellationID,
            requestID: requestID,
            grantID: grant.grantID,
            reservationID: committed.reservationID,
            scope: committed.scope,
            fence: committed.fence,
            actor: actor,
            reason: "test-cancel",
            requestedAt: now.addingTimeInterval(3),
            state: .requested,
            effectiveAt: nil
        )
        let cancelPayload = try AcceleratorXPCCancelPayload(
            executionRequest: request,
            cancellation: cancellation,
            claim: claim,
            grant: grant,
            reservation: committed,
            inventory: inventory,
            observedAt: now.addingTimeInterval(3)
        )
        let cancelRequest = try AcceleratorXPCRequest(
            operation: .cancel,
            requestID: cancellationID,
            timeoutMilliseconds: 1_000,
            payload: .cancel(cancelPayload)
        )
        let revocationID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
        let revocation = try AcceleratorRevocationRecord(
            revocationID: revocationID,
            targetKind: .reservation,
            targetIdentifier: committed.reservationID.uuidString.lowercased(),
            scope: committed.scope,
            fence: committed.fence,
            actor: context,
            reason: "test-revoke",
            evidenceDigest: try digest("e"),
            revokedAt: now.addingTimeInterval(3)
        )
        let revokePayload = try AcceleratorXPCRevokePayload(
            revocation: revocation,
            claim: claim,
            grant: grant,
            reservation: committed,
            observedAt: now.addingTimeInterval(3)
        )
        let revokeRequest = try AcceleratorXPCRequest(
            operation: .revoke,
            requestID: revocationID,
            timeoutMilliseconds: 1_000,
            payload: .revoke(revokePayload)
        )
        return ExecutionFixture(
            requestID: requestID,
            cancellationID: cancellationID,
            modelArtifact: modelArtifact,
            binding: AcceleratorXPCExecutionBinding(
                request: request,
                claim: claim,
                grant: grant,
                reservation: committed,
                inventory: inventory
            ),
            executeRequest: executeRequest,
            cancelRequest: cancelRequest,
            revokeRequest: revokeRequest
        )
    }

    private func makeInventory() throws -> AcceleratorInventorySnapshot {
        let evidence = try digest("a")
        let selfTest: (AcceleratorExecutionMode) throws -> AcceleratorHostNativeExecutionEvidence = { mode in
            try AcceleratorHostNativeExecutionEvidence(
                mode: mode,
                backendIdentifier: mode.rawValue,
                frameworkIdentifier: "host-native",
                operatingSystem: "macos",
                executionDigest: evidence,
                provenanceDigest: evidence,
                observedGeneration: 7,
                observedAt: self.now,
                completedAt: self.now.addingTimeInterval(1)
            )
        }
        return try AcceleratorInventorySnapshot(
            snapshotID: snapshotID,
            hostID: hostID,
            observedAt: now,
            observedGeneration: 7,
            modeEvidence: [
                try AcceleratorModeEvidence(
                    mode: .coreML,
                    status: .available,
                    evidenceDigest: evidence,
                    source: .hostNativeExecutionSelfTest,
                    observedGeneration: 7,
                    executionEvidence: try selfTest(.coreML)
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
                try AcceleratorModeEvidence(
                    mode: .metal,
                    status: .available,
                    evidenceDigest: evidence,
                    source: .hostNativeExecutionSelfTest,
                    observedGeneration: 7,
                    executionEvidence: try selfTest(.metal)
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

    private func digest(_ character: Character) throws -> AcceleratorDigest {
        try AcceleratorDigest(String(repeating: character, count: 64))
    }

    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let workloadID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let snapshotID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let claimID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
    private let reservationID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    private let grantID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    private var authentication: AcceleratorAuthenticationContext {
        get throws { try makeAuthentication() }
    }

    private func makeAuthentication(
        subjectID: String,
        sessionID: String = "session-1",
        credentialID: String? = nil,
        digestCharacter: Character = "c"
    ) throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: subjectID,
            sessionID: sessionID,
            credentialID: credentialID,
            authenticationDigest: try digest(digestCharacter),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func makeAuthentication() throws -> AcceleratorAuthenticationContext {
        try makeAuthentication(subjectID: "subject-owner")
    }

    private var daemonProof: AcceleratorXPCCodeIdentityProof {
        get throws {
            try AcceleratorXPCCodeIdentityProof(
                teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                signingIdentifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
                codeDirectoryHash: String(repeating: "a", count: 40),
                entitlementProjection: AcceleratorXPCIdentityPolicy.daemonEntitlementProjection
            )
        }
    }

    private var serviceProof: AcceleratorXPCCodeIdentityProof {
        get throws {
            try AcceleratorXPCCodeIdentityProof(
                teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
                codeDirectoryHash: String(repeating: "b", count: 40),
                entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
            )
        }
    }
}

private struct ExecutionFixture: Sendable {
    let requestID: UUID
    let cancellationID: UUID
    let modelArtifact: AcceleratorXPCModelArtifact
    let binding: AcceleratorXPCExecutionBinding
    let executeRequest: AcceleratorXPCRequest
    let cancelRequest: AcceleratorXPCRequest
    let revokeRequest: AcceleratorXPCRequest
}

private func executePayload(
    from request: AcceleratorXPCRequest
) -> AcceleratorXPCExecutePayload? {
    guard case .execute(let payload) = request.payload else { return nil }
    return payload
}

private func cancelPayload(
    from request: AcceleratorXPCRequest
) -> AcceleratorXPCCancelPayload? {
    guard case .cancel(let payload) = request.payload else { return nil }
    return payload
}

private actor CancellationFlag {
    private var storage = false

    func set() {
        storage = true
    }

    func isSet() -> Bool {
        storage
    }

    func waitUntilSet() async -> Bool {
        for _ in 0..<1_000 {
            if storage {
                return true
            }
            await Task.yield()
        }
        return storage
    }
}

private actor SuspendedBackend: AcceleratorXPCBackend {
    private let artifact: AcceleratorXPCModelArtifact
    private var startedIDs: Set<UUID> = []
    private var cancelledIDs: Set<UUID> = []

    init(modelArtifact: AcceleratorXPCModelArtifact) {
        self.artifact = modelArtifact
    }

    func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact {
        guard modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }
        return artifact
    }

    func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult {
        let requestID = context.payload.request.requestID
        startedIDs.insert(requestID)
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch is CancellationError {
            cancelledIDs.insert(requestID)
            throw CancellationError()
        }
        throw AcceleratorXPCBackendError.unavailable
    }

    func waitUntilStarted(count: Int) async -> Bool {
        for _ in 0..<10_000 {
            if startedIDs.count >= count { return true }
            await Task.yield()
        }
        return false
    }

    func wasCancelled(_ requestID: UUID) -> Bool {
        cancelledIDs.contains(requestID)
    }

    func waitUntilCancelled(_ requestID: UUID) async -> Bool {
        for _ in 0..<1_000 {
            if cancelledIDs.contains(requestID) {
                return true
            }
            await Task.yield()
        }
        return cancelledIDs.contains(requestID)
    }
}

private actor EvidenceBackend: AcceleratorXPCBackend {
    private let artifact: AcceleratorXPCModelArtifact
    private let provenanceDigest: AcceleratorDigest
    private let source: AcceleratorEvidenceSource

    init(
        modelArtifact: AcceleratorXPCModelArtifact,
        provenanceDigest: AcceleratorDigest,
        source: AcceleratorEvidenceSource
    ) {
        self.artifact = modelArtifact
        self.provenanceDigest = provenanceDigest
        self.source = source
    }

    func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact {
        guard modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }
        return artifact
    }

    func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult {
        let request = context.payload.request
        let inventory = context.payload.inventory
        let completedAt = context.payload.observedAt.addingTimeInterval(3)
        let usage = try AcceleratorMeasuredUsage(
            budget: request.budget,
            source: .callerMeasuredUsage,
            observedGeneration: inventory.observedGeneration,
            authenticatedBy: request.authentication,
            observedAt: context.payload.observedAt
        )
        let provenance = try AcceleratorExecutionProvenance(
            requestID: request.requestID,
            mode: request.mode,
            modelHash: request.modelHash,
            inventorySnapshotID: inventory.snapshotID,
            inventoryGeneration: inventory.observedGeneration,
            evidenceDigest: provenanceDigest,
            source: source,
            authenticatedBy: request.authentication,
            recordedAt: context.payload.observedAt
        )
        return try AcceleratorExecutionResult(
            requestID: request.requestID,
            grantID: request.grantID,
            reservationID: request.reservationID,
            scope: request.scope,
            mode: request.mode,
            modelHash: request.modelHash,
            fence: request.fence,
            outcome: .succeeded,
            outputBytes: 0,
            outputDigest: nil,
            usage: usage,
            provenance: provenance,
            completedAt: completedAt,
            authenticatedBy: request.authentication,
            errorCode: nil
        )
    }
}

private actor NonCooperativeBackend: AcceleratorXPCBackend {
    private let artifact: AcceleratorXPCModelArtifact
    private var pending: CheckedContinuation<AcceleratorExecutionResult, Error>?
    private var pendingContext: AcceleratorXPCBackendExecutionContext?
    private var started = false

    init(modelArtifact: AcceleratorXPCModelArtifact) {
        self.artifact = modelArtifact
    }

    func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact {
        guard modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }
        return artifact
    }

    func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult {
        started = true
        pendingContext = context
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<10_000 {
            if started { return true }
            await Task.yield()
        }
        return started
    }

    func release() {
        guard let pending, let context = pendingContext else { return }
        self.pending = nil
        self.pendingContext = nil
        let now = Date(timeIntervalSince1970: 1_754_000_005)
        // The service observes cancellation before accepting this result.
        let result: AcceleratorExecutionResult
        do {
            result = try AcceleratorExecutionResult(
                requestID: context.payload.request.requestID,
                grantID: context.payload.request.grantID,
                reservationID: context.payload.request.reservationID,
                scope: context.payload.request.scope,
                mode: context.payload.request.mode,
                modelHash: context.payload.request.modelHash,
                fence: context.payload.request.fence,
                outcome: .cancelled,
                outputBytes: 0,
                outputDigest: nil,
                usage: nil,
                provenance: nil,
                completedAt: now,
                authenticatedBy: context.payload.request.authentication,
                errorCode: .invalidCancellation
            )
        } catch {
            pending.resume(throwing: error)
            return
        }
        pending.resume(returning: result)
    }

}

private actor UnobservedTerminationBackend: AcceleratorXPCBackend {
    private let artifact: AcceleratorXPCModelArtifact

    init(modelArtifact: AcceleratorXPCModelArtifact) {
        self.artifact = modelArtifact
    }

    func inventory(
        for query: AcceleratorXPCInventoryQuery
    ) async throws -> AcceleratorInventorySnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func status(
        for query: AcceleratorXPCStatusQuery
    ) async throws -> AcceleratorXPCStatusSnapshot {
        throw AcceleratorXPCBackendError.unsupported
    }

    func modelArtifact(
        for modelHash: AcceleratorDigest
    ) async throws -> AcceleratorXPCModelArtifact {
        guard modelHash == artifact.modelHash else {
            throw AcceleratorXPCBackendError.unavailable
        }
        return artifact
    }

    func execute(
        _ context: AcceleratorXPCBackendExecutionContext
    ) async throws -> AcceleratorExecutionResult {
        throw AcceleratorXPCWorkerTerminationUncertain()
    }
}

private struct ServiceIdentityInspector: AcceleratorXPCIdentityInspector {
    let proof: AcceleratorXPCCodeIdentityProof

    func current() throws -> AcceleratorXPCCodeIdentityProof {
        proof
    }

    func peer(of connection: xpc_connection_t) throws -> AcceleratorXPCCodeIdentityProof {
        proof
    }
}
