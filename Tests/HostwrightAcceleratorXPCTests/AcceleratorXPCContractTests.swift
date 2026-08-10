import Foundation
import XCTest
@preconcurrency import XPC
@testable import HostwrightAccelerator
@testable import HostwrightAcceleratorXPC
@testable import HostwrightState

final class AcceleratorXPCContractTests: XCTestCase {
    func testConcurrencyBudgetIsBoundedBeforeRegistryAdmission() {
        XCTAssertThrowsError(
            try AcceleratorBudgetVector(
                memoryBytes: 1,
                computeUnits: 1,
                concurrencyUnits: UInt64(AcceleratorLimits.maxConcurrency) + 1
            )
        )
    }

    func testInventoryRequestRoundTripsThroughStrictXPCCodec() throws {
        let requester = try makeAuthentication()
        let query = try AcceleratorXPCInventoryQuery(
            hostID: hostID,
            requester: requester,
            observedAt: now
        )
        let request = try AcceleratorXPCRequest(
            operation: .inventory,
            requestID: requestID,
            timeoutMilliseconds: 1_000,
            payload: .inventory(query)
        )
        let decoded = try AcceleratorXPCMessageCodec.decodeRequest(
            AcceleratorXPCMessageCodec.encodeRequest(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.idempotencyDigest, request.idempotencyDigest)
    }

    func testUnknownAndDuplicateWireFieldsFailClosed() throws {
        let requester = try makeAuthentication()
        let query = try AcceleratorXPCInventoryQuery(
            hostID: hostID,
            requester: requester,
            observedAt: now
        )
        let request = try AcceleratorXPCRequest(
            operation: .inventory,
            requestID: requestID,
            timeoutMilliseconds: 1_000,
            payload: .inventory(query)
        )
        let message = try AcceleratorXPCMessageCodec.encodeRequest(request)
        xpc_dictionary_set_string(message, "unexpected", "field")
        XCTAssertThrowsError(try AcceleratorXPCMessageCodec.decodeRequest(message))

        let duplicatePayload = Data(
            #"{"kind":"inventory","kind":"inventory","inventory":{}}"#.utf8
        )
        let hostile = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(hostile, "protocolVersion", 1)
        xpc_dictionary_set_string(hostile, "operation", "inventory")
        xpc_dictionary_set_string(hostile, "requestID", requestID.uuidString.lowercased())
        xpc_dictionary_set_uint64(hostile, "timeoutMilliseconds", 1_000)
        xpc_dictionary_set_string(
            hostile,
            "idempotencyDigest",
            String(repeating: "a", count: 64)
        )
        duplicatePayload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(hostile, "payload", bytes.baseAddress, bytes.count)
        }
        XCTAssertThrowsError(try AcceleratorXPCMessageCodec.decodeRequest(hostile))
    }

    func testNestedUnknownAndDuplicateFieldsFailClosed() throws {
        let payload = try AcceleratorXPCWireJSON.encode(
            AcceleratorXPCRequestPayload.inventory(
                try AcceleratorXPCInventoryQuery(
                    hostID: hostID,
                    requester: try makeAuthentication(),
                    observedAt: now
                )
            )
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        var inventory = try XCTUnwrap(object["inventory"] as? [String: Any])
        inventory["unexpected"] = true
        object["inventory"] = inventory
        let unknown = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCRequestPayload.self,
                from: unknown
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorXPCValidationError)?.code,
                .unknownField
            )
        }

        let encoded = String(decoding: payload, as: UTF8.self)
        let duplicate = encoded.replacingOccurrences(
            of: "\"inventory\":{\"contractVersion\":",
            with: "\"inventory\":{\"contractVersion\":1,\"contractVersion\":"
        )
        XCTAssertThrowsError(
            try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCRequestPayload.self,
                from: Data(duplicate.utf8)
            )
        )
    }

    func testJSONNodeBudgetRejectsHostileContainerExpansion() throws {
        let values = String(repeating: "0,", count: AcceleratorXPCContract.maxJSONNodeCount)
            + "0"
        let data = Data("{\"values\":[\(values)]}".utf8)
        XCTAssertThrowsError(
            try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCRequestPayload.self,
                from: data
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorXPCValidationError)?.code,
                .payloadTooLarge
            )
            XCTAssertEqual(
                (error as? AcceleratorXPCValidationError)?.field,
                "payload.nodes"
            )
        }
    }

    func testServiceWithoutBackendReturnsExplicitUnavailableAndReplays() async throws {
        let requester = try makeAuthentication()
        let query = try AcceleratorXPCInventoryQuery(
            hostID: hostID,
            requester: requester,
            observedAt: now
        )
        let request = try AcceleratorXPCRequest(
            operation: .inventory,
            requestID: requestID,
            timeoutMilliseconds: 1_000,
            payload: .inventory(query)
        )
        let service = try makeService()
        let first = try await service.handle(request, peer: daemonProof)
        XCTAssertEqual(first.status, .unavailable)
        XCTAssertEqual(first.error?.code, .backendUnavailable)
        XCTAssertFalse(first.replayed)

        let replay = try await service.handle(request, peer: daemonProof)
        XCTAssertEqual(replay.operation, first.operation)
        XCTAssertEqual(replay.requestID, first.requestID)
        XCTAssertEqual(replay.status, first.status)
        XCTAssertEqual(replay.idempotencyDigest, first.idempotencyDigest)
        XCTAssertEqual(replay.serviceProof, first.serviceProof)
        XCTAssertEqual(replay.payload, first.payload)
        XCTAssertEqual(replay.error, first.error)
        XCTAssertTrue(replay.replayed)
    }

    func testDurableReplaySurvivesServiceRestartAndRejectsConflictingDuplicate() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-xpc-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: parent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        }
        let database = parent.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: database.path)
        try store.migrate()

        let request = try makeInventoryRequest(requestID: requestID)
        let firstService = try AcceleratorXPCService(
            identityInspector: TestIdentityInspector(proof: try serviceProof),
            durableReplayStore: AcceleratorStateXPCReplayStore(store: store)
        )
        let first = try await firstService.handle(request, peer: try daemonProof)
        XCTAssertEqual(first.status, .unavailable)
        XCTAssertFalse(first.replayed)

        let reopenedStore = SQLiteStateStore(path: database.path)
        try reopenedStore.validateSchema()
        let secondService = try AcceleratorXPCService(
            identityInspector: TestIdentityInspector(proof: try serviceProof),
            durableReplayStore: AcceleratorStateXPCReplayStore(store: reopenedStore)
        )
        let replay = try await secondService.handle(request, peer: try daemonProof)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.status, first.status)
        XCTAssertEqual(replay.error, first.error)

        let conflicting = try makeInventoryRequest(
            requestID: requestID,
            timeoutMilliseconds: 1_001
        )
        do {
            _ = try await secondService.handle(conflicting, peer: try daemonProof)
            XCTFail("a reused request ID with a different digest must fail closed")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.idempotencyConflict))
        }

        let history = try reopenedStore.acceleratorState.log(kind: .xpcReplay)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(
            try reopenedStore.acceleratorState.current(
                AcceleratorXPCReplayStateRecord.self,
                kind: .xpcReplay,
                recordID: requestID.uuidString.lowercased()
        )?.payload.state,
            .completed
        )
    }

    func testDurableReplayReopenOfPendingRequestIsInFlight() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-xpc-pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: parent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        }
        let store = SQLiteStateStore(
            path: parent.appendingPathComponent("state.sqlite").path
        )
        try store.migrate()
        let request = try makeInventoryRequest(requestID: requestID)
        let identity = try AcceleratorXPCDurableReplayIdentity(
            requestID: request.requestID,
            operation: request.operation.rawValue,
            protocolVersion: request.protocolVersion,
            idempotencyDigest: request.idempotencyDigest
        )
        let firstStore = AcceleratorStateXPCReplayStore(store: store)
        switch try firstStore.begin(identity, observedAt: now) {
        case .admitted:
            break
        default:
            XCTFail("a new durable request must be admitted")
        }

        let reopened = SQLiteStateStore(path: store.path)
        try reopened.validateSchema()
        let secondStore = AcceleratorStateXPCReplayStore(store: reopened)
        switch try secondStore.begin(identity, observedAt: now) {
        case .inFlight:
            break
        default:
            XCTFail("a pending request must remain in-flight after reopen")
        }

        let conflictingRequest = try makeInventoryRequest(
            requestID: requestID,
            timeoutMilliseconds: 1_001
        )
        let conflictingIdentity = try AcceleratorXPCDurableReplayIdentity(
            requestID: conflictingRequest.requestID,
            operation: conflictingRequest.operation.rawValue,
            protocolVersion: conflictingRequest.protocolVersion,
            idempotencyDigest: conflictingRequest.idempotencyDigest
        )
        XCTAssertThrowsError(
            try secondStore.begin(conflictingIdentity, observedAt: now)
        ) { error in
            XCTAssertEqual(
                error as? AcceleratorXPCDurableReplayStoreError,
                .idempotencyConflict
            )
        }
    }

    func testDurableReplayRejectsTamperedCurrentRecordAfterReopen() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-xpc-tampered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            try? FileManager.default.removeItem(at: parent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        }
        let database = parent.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: database.path)
        try store.migrate()
        let request = try makeInventoryRequest(requestID: requestID)
        let service = try AcceleratorXPCService(
            identityInspector: TestIdentityInspector(proof: try serviceProof),
            durableReplayStore: AcceleratorStateXPCReplayStore(store: store)
        )
        _ = try await service.handle(request, peer: try daemonProof)

        try store.withConnection { connection in
            try connection.run(
                "UPDATE accelerator_state_current SET payload_json_redacted = ? WHERE type = ? AND record_id = ?",
                bindings: [
                    .text("{\"envelopeVersion\":1}"),
                    .text("accelerator.state.xpc-replay"),
                    .text(requestID.uuidString.lowercased())
                ]
            )
        }

        let reopened = SQLiteStateStore(path: database.path)
        let reopenedService = try AcceleratorXPCService(
            identityInspector: TestIdentityInspector(proof: try serviceProof),
            durableReplayStore: AcceleratorStateXPCReplayStore(store: reopened)
        )
        do {
            _ = try await reopenedService.handle(request, peer: try daemonProof)
            XCTFail("a tampered current replay record must not authorize replay")
        } catch let error as AcceleratorXPCServiceError {
            XCTAssertEqual(error, .registry(.replayHistoryUnavailable))
        }
    }

    func testClientRejectsMismatchedLiveServiceProof() async throws {
        let request = try makeInventoryRequest(requestID: requestID)
        let service = try makeService()
        let response = try await service.handle(request, peer: daemonProof)
        let mismatchedProof = try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
            codeDirectoryHash: String(repeating: "c", count: 40),
            entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
        )
        XCTAssertThrowsError(
            try AcceleratorXPCClient.validate(
                response: response,
                for: request,
                liveServiceProof: mismatchedProof
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCClientError, .invalidResponse)
        }
    }

    func testProductionClientRequiresDaemonIdentity() async throws {
        let clientProof = try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: "hostwright-control",
            codeDirectoryHash: String(repeating: "d", count: 40),
            entitlementProjection: AcceleratorXPCIdentityPolicy.clientEntitlementProjection
        )
        let client = try AcceleratorXPCClient(
            identityInspector: TestIdentityInspector(proof: clientProof)
        )
        do {
            _ = try await client.send(try makeInventoryRequest(requestID: requestID))
            XCTFail("a non-daemon client identity must not activate the service connection")
        } catch let error as AcceleratorXPCClientError {
            XCTAssertEqual(error, .authenticationFailed)
        }
    }

    func testIdentityEntitlementsAreRoleSpecific() throws {
        let daemon = try daemonProof
        XCTAssertNoThrow(try daemon.validate(as: .daemon))
        XCTAssertThrowsError(try daemon.validate(as: .service)) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .identifierMismatch)
        }

        let serviceWithoutSandbox = try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
            codeDirectoryHash: String(repeating: "b", count: 40),
            entitlementProjection: AcceleratorXPCIdentityPolicy.daemonEntitlementProjection
        )
        XCTAssertThrowsError(
            try AcceleratorXPCService(
                backend: nil,
                identityInspector: TestIdentityInspector(proof: serviceWithoutSandbox)
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .entitlementMismatch)
        }
        XCTAssertNoThrow(try serviceProof.validate(as: .service))

        let inspectedDaemon = try AcceleratorXPCSecCode.proof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
            unique: Data(repeating: 0xAB, count: 20),
            entitlements: nil
        )
        XCTAssertNoThrow(try inspectedDaemon.validate(as: .daemon))
        XCTAssertThrowsError(try inspectedDaemon.validate(as: .service)) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .identifierMismatch)
        }

        XCTAssertThrowsError(
            try AcceleratorXPCSecCode.proof(
                teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                signingIdentifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
                unique: Data(repeating: 0xAC, count: 20),
                entitlements: ["com.apple.security.network.client": true]
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .entitlementMismatch)
        }
        XCTAssertThrowsError(
            try AcceleratorXPCSecCode.proof(
                teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                signingIdentifier: AcceleratorXPCIdentityPolicy.daemonSigningIdentifier,
                unique: Data(repeating: 0xAD, count: 20),
                entitlements: [
                    "com.apple.security.app-sandbox": true,
                    "com.apple.security.network.client": true
                ]
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCIdentityError, .entitlementMismatch)
        }
    }

    func testPeerProofMismatchIsRejectedAfterTransportRequirementBinding() throws {
        let request = try makeInventoryRequest(requestID: requestID)
        let response = try responseFor(request)
        let proofFromDifferentPeer = try AcceleratorXPCCodeIdentityProof(
            teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
            signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
            codeDirectoryHash: String(repeating: "e", count: 40),
            entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
        )

        XCTAssertThrowsError(
            try AcceleratorXPCClient.validate(
                response: response,
                for: request,
                liveServiceProof: proofFromDifferentPeer
            )
        ) { error in
            XCTAssertEqual(error as? AcceleratorXPCClientError, .invalidResponse)
        }
    }

    func testBoundsRejectTimeoutAndOversizedPayload() throws {
        let requester = try makeAuthentication()
        let query = try AcceleratorXPCInventoryQuery(
            hostID: hostID,
            requester: requester,
            observedAt: now
        )
        XCTAssertThrowsError(
            try AcceleratorXPCRequest(
                operation: .inventory,
                requestID: requestID,
                timeoutMilliseconds: 0,
                payload: .inventory(query)
            )
        )

        let payload = Data(
            repeating: 0,
            count: AcceleratorXPCContract.maxMessageBytes + 1
        )
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, "protocolVersion", 1)
        xpc_dictionary_set_string(message, "operation", "inventory")
        xpc_dictionary_set_string(message, "requestID", requestID.uuidString.lowercased())
        xpc_dictionary_set_uint64(message, "timeoutMilliseconds", 1_000)
        xpc_dictionary_set_string(
            message,
            "idempotencyDigest",
            String(repeating: "a", count: 64)
        )
        payload.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(message, "payload", bytes.baseAddress, bytes.count)
        }
        XCTAssertThrowsError(try AcceleratorXPCMessageCodec.decodeRequest(message))
    }

    func testResponseStatusBindsItsErrorCodeDuringConstructionAndDecode() throws {
        let request = try makeInventoryRequest(requestID: requestID)
        let mismatchedError = try AcceleratorXPCError(code: .cancelled)
        XCTAssertThrowsError(
            try AcceleratorXPCResponse(
                operation: request.operation,
                requestID: request.requestID,
                status: .unavailable,
                idempotencyDigest: request.idempotencyDigest,
                serviceProof: serviceProof,
                error: mismatchedError
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorXPCValidationError)?.field,
                "response.error.code"
            )
        }

        let valid = try responseFor(request)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
        )
        var error = try XCTUnwrap(object["error"] as? [String: Any])
        error["code"] = AcceleratorXPCErrorCode.cancelled.rawValue
        object["error"] = error
        let hostile = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try AcceleratorXPCWireJSON.decode(
                AcceleratorXPCResponse.self,
                from: hostile
            )
        ) { error in
            XCTAssertEqual(
                (error as? AcceleratorXPCValidationError)?.field,
                "response.error.code"
            )
        }
    }

    func testRegistryFailsClosedWhenReplayHistoryIsExhausted() throws {
        let limits = try AcceleratorXPCRegistryLimits(
            maxCompletedResponses: 1,
            maxRequestHistory: 2,
            maxCancellationRecords: 1,
            maxRevocationKeys: 1
        )
        let registry = try AcceleratorXPCRequestRegistry(
            maxConcurrent: 2,
            limits: limits
        )
        let first = try makeInventoryRequest(requestID: requestID)
        let secondID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let second = try makeInventoryRequest(requestID: secondID, timeoutMilliseconds: 1_001)
        XCTAssertEqual(try registry.begin(first), .admitted)
        registry.finish(first, response: try responseFor(first))
        if case .replayed = try registry.begin(first) {
            // Expected replay path.
        } else {
            XCTFail("completed request did not replay")
        }

        XCTAssertEqual(try registry.begin(second), .admitted)
        registry.finish(second, response: try responseFor(second))
        XCTAssertThrowsError(try registry.begin(first)) { error in
            XCTAssertEqual(
                error as? AcceleratorXPCRequestRegistryError,
                .replayHistoryUnavailable
            )
        }
        let thirdID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        XCTAssertThrowsError(try registry.begin(try makeInventoryRequest(requestID: thirdID))) { error in
            XCTAssertEqual(
                error as? AcceleratorXPCRequestRegistryError,
                .replayHistoryExhausted
            )
        }
    }

    private let hostID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let requestID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

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

    private func makeService() throws -> AcceleratorXPCService {
        try AcceleratorXPCService(
            backend: nil,
            identityInspector: TestIdentityInspector(
                proof: try AcceleratorXPCCodeIdentityProof(
                    teamIdentifier: AcceleratorXPCIdentityPolicy.teamIdentifier,
                    signingIdentifier: AcceleratorXPCIdentityPolicy.serviceIdentifier,
                    codeDirectoryHash: String(repeating: "b", count: 40),
                    entitlementProjection: AcceleratorXPCIdentityPolicy.serviceEntitlementProjection
                )
            )
        )
    }

    private func makeAuthentication() throws -> AcceleratorAuthenticationContext {
        try AcceleratorAuthenticationContext(
            subjectID: "subject-owner",
            sessionID: "session-1",
            authenticationDigest: try AcceleratorDigest(String(repeating: "c", count: 64)),
            authenticatedAt: now,
            expiresAt: now.addingTimeInterval(300)
        )
    }

    private func makeInventoryRequest(
        requestID: UUID,
        timeoutMilliseconds: Int = 1_000
    ) throws -> AcceleratorXPCRequest {
        try AcceleratorXPCRequest(
            operation: .inventory,
            requestID: requestID,
            timeoutMilliseconds: timeoutMilliseconds,
            payload: .inventory(
                try AcceleratorXPCInventoryQuery(
                    hostID: hostID,
                    requester: try makeAuthentication(),
                    observedAt: now
                )
            )
        )
    }

    private func responseFor(_ request: AcceleratorXPCRequest) throws -> AcceleratorXPCResponse {
        try AcceleratorXPCResponse(
            operation: request.operation,
            requestID: request.requestID,
            status: .unavailable,
            idempotencyDigest: request.idempotencyDigest,
            serviceProof: serviceProof,
            error: try AcceleratorXPCError(code: .backendUnavailable)
        )
    }
}

private struct TestIdentityInspector: AcceleratorXPCIdentityInspector {
    let proof: AcceleratorXPCCodeIdentityProof

    func current() throws -> AcceleratorXPCCodeIdentityProof {
        proof
    }

    func peer(of connection: xpc_connection_t) throws -> AcceleratorXPCCodeIdentityProof {
        proof
    }
}
