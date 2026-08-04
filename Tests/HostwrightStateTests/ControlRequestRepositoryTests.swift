import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightState

final class ControlRequestRepositoryTests: XCTestCase {
  private let createdAt = "2026-08-02T20:00:00Z"
  private let updatedAt = "2026-08-02T20:01:00Z"
  private let expiresAt = "2026-08-02T21:00:00Z"

  func testRecordsAtomicallyAndPersistsAfterReopen() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try bootstrapOwner(in: store)
    let repository = makeRepository(store)
    let submission = ControlRequestSubmission(
      request: request(id: "request-1", key: "idem-1"), idempotencyExpiresAt: expiresAt)

    XCTAssertEqual(try repository.record(submission), submission.request)
    let reopened = makeRepository(SQLiteStateStore(path: path))
    XCTAssertEqual(try reopened.load("request-1"), submission.request)
    XCTAssertEqual(
      try reopened.load(subjectID: "owner", idempotencyKey: "idem-1"), submission.request)
    XCTAssertEqual(
      try reopened.loadIdempotency(subjectID: "owner", idempotencyKey: "idem-1")?.status,
      .accepted)
  }

  func testTerminalResponsePersistsExactlyAcrossReopenAndRejectsMismatchedEnvelope() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    try bootstrapOwner(in: store)
    let repository = makeRepository(store)
    _ = try repository.record(ControlRequestSubmission(
      request: request(id: "response-request", key: "response-key"),
      idempotencyExpiresAt: expiresAt
    ))

    let response = ControlResponseEnvelope(
      requestID: "response-request",
      status: .completed,
      reasonCode: .completed,
      operationRef: "unary:" + String(repeating: "c", count: 64),
      result: .object(["generation": .integer(3), "state": .string("active")])
    )
    let canonicalResponse = try ControlPlaneCanonicalJSON.encode(response)
    let completed = try repository.updateTerminal(
      requestID: "response-request",
      status: .completed,
      operationReference: response.operationRef,
      responseCanonicalJSON: canonicalResponse,
      updatedAt: updatedAt
    )
    XCTAssertEqual(completed.responseCanonicalJSON, canonicalResponse)

    let reopened = makeRepository(SQLiteStateStore(path: path))
    let reloaded = try XCTUnwrap(reopened.load("response-request"))
    XCTAssertEqual(reloaded.responseCanonicalJSON, canonicalResponse)
    XCTAssertEqual(
      try JSONDecoder().decode(ControlResponseEnvelope.self, from: canonicalResponse),
      response
    )

    _ = try repository.record(ControlRequestSubmission(
      request: request(id: "mismatch-request"), idempotencyExpiresAt: nil
    ))
    let mismatched = try ControlPlaneCanonicalJSON.encode(ControlResponseEnvelope(
      requestID: "different-request",
      status: .completed,
      reasonCode: .completed
    ))
    XCTAssertThrowsError(try repository.updateTerminal(
      requestID: "mismatch-request",
      status: .completed,
      operationReference: nil,
      responseCanonicalJSON: mismatched,
      updatedAt: updatedAt
    ))
    XCTAssertEqual(try repository.load("mismatch-request")?.status, .accepted)
  }

  func testExactReplayReturnsPriorRecordAndDigestConflictIsRejected() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let original = ControlRequestSubmission(
        request: request(id: "request-1", key: "idem-1"), idempotencyExpiresAt: expiresAt)
      XCTAssertEqual(try repository.record(original), original.request)
      XCTAssertEqual(try repository.recordOrReplay(original), .replayed(original.request))

      let conflict = ControlRequestSubmission(
        request: request(id: "request-2", key: "idem-1", digestCharacter: "b"),
        idempotencyExpiresAt: expiresAt)
      XCTAssertThrowsError(try repository.record(conflict)) { error in
        XCTAssertEqual(
          error as? StateStoreError,
          .invalidRecord("Idempotency key is already bound to a different request digest."))
      }
    }
  }

  func testIdempotencyKeysAreSubjectIsolated() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      try store.controlIdentities.declare(
        identity(subjectID: "other", declaredBy: "owner", hash: "b"))
      let repository = makeRepository(store)
      let owner = ControlRequestSubmission(
        request: request(id: "owner-request", key: "shared"), idempotencyExpiresAt: expiresAt)
      let other = ControlRequestSubmission(
        request: request(
          id: "other-request", subject: "other", key: "shared", digestCharacter: "b"),
        idempotencyExpiresAt: expiresAt)
      XCTAssertEqual(try repository.record(owner), owner.request)
      XCTAssertEqual(try repository.record(other), other.request)
      XCTAssertEqual(
        try repository.load(subjectID: "owner", idempotencyKey: "shared"), owner.request)
      XCTAssertEqual(
        try repository.load(subjectID: "other", idempotencyKey: "shared"), other.request)
    }
  }

  func testOnlyAcceptedRequestsMayTransitionOnceToTerminalStatus() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let accepted = ControlRequestSubmission(
        request: request(id: "accepted", key: "accepted-key"), idempotencyExpiresAt: expiresAt)
      let rejected = ControlRequestSubmission(
        request: request(id: "rejected", status: .rejected), idempotencyExpiresAt: nil)
      _ = try repository.record(accepted)
      _ = try repository.record(rejected)

      let bound = try repository.recordAcceptedOperationReference(
        requestID: "accepted", operationReference: "operation-1",
        updatedAt: "2026-08-02T20:01:30Z"
      )
      XCTAssertEqual(bound.status, .accepted)
      XCTAssertEqual(bound.operationReference, "operation-1")
      XCTAssertEqual(
        try repository.recordAcceptedOperationReference(
          requestID: "accepted", operationReference: "operation-1",
          updatedAt: "2026-08-02T20:01:31Z"
        ),
        bound
      )
      XCTAssertThrowsError(
        try repository.recordAcceptedOperationReference(
          requestID: "accepted", operationReference: "operation-other",
          updatedAt: "2026-08-02T20:01:32Z"
        )
      )

      let completed = try repository.updateTerminal(
        requestID: "accepted", status: .completed, operationReference: "operation-1",
        updatedAt: "2026-08-02T20:02:00Z")
      XCTAssertEqual(completed.status, .completed)
      XCTAssertEqual(completed.operationReference, "operation-1")
      XCTAssertEqual(
        try repository.loadIdempotency(subjectID: "owner", idempotencyKey: "accepted-key")?.status,
        .completed)
      XCTAssertThrowsError(
        try repository.updateTerminal(
          requestID: "accepted", status: .error, operationReference: nil,
          updatedAt: "2026-08-02T20:03:00Z"))
      XCTAssertThrowsError(
        try repository.updateTerminal(
          requestID: "rejected", status: .completed, operationReference: nil,
          updatedAt: "2026-08-02T20:03:00Z"))
      let acceptedForRejection = ControlRequestSubmission(
        request: request(id: "accepted-rejection"), idempotencyExpiresAt: nil)
      _ = try repository.record(acceptedForRejection)
      XCTAssertEqual(
        try repository.updateTerminal(
          requestID: "accepted-rejection", status: .rejected, operationReference: nil,
          updatedAt: "2026-08-02T20:03:00Z"
        ).status,
        .rejected
      )
      XCTAssertThrowsError(
        try repository.updateTerminal(
          requestID: "accepted-rejection", status: .rejected,
          operationReference: "forbidden", updatedAt: "2026-08-02T20:04:00Z"))

      let acceptedForCompletion = ControlRequestSubmission(
        request: request(id: "accepted-completion"), idempotencyExpiresAt: nil)
      _ = try repository.record(acceptedForCompletion)
      _ = try repository.recordAcceptedOperationReference(
        requestID: "accepted-completion", operationReference: "operation-preserved",
        updatedAt: "2026-08-02T20:04:00Z"
      )
      let preserved = try repository.updateTerminal(
        requestID: "accepted-completion", status: .completed, operationReference: nil,
        updatedAt: "2026-08-02T20:05:00Z"
      )
      XCTAssertEqual(preserved.operationReference, "operation-preserved")
    }
  }

  func testRestartRecoveryTerminatesOnlyInterruptedUnaryRequests() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      _ = try repository.record(ControlRequestSubmission(
        request: request(
          id: "unary-interrupted", key: "unary-key",
          operationReference: "unary:" + String(repeating: "a", count: 64)
        ),
        idempotencyExpiresAt: expiresAt
      ))
      _ = try repository.record(ControlRequestSubmission(
        request: request(
          id: "stream-active", key: "stream-key",
          operationReference: "stream:" + String(repeating: "b", count: 64)
        ),
        idempotencyExpiresAt: expiresAt
      ))

      let interrupted = try repository.interruptedUnaryRequests()
      XCTAssertEqual(interrupted.map(\.requestID), ["unary-interrupted"])
      let recovered = try interrupted.map {
        try repository.markInterruptedUnaryRequest(
          requestID: $0.requestID,
          operationReference: $0.operationReference!,
          updatedAt: "2026-08-02T20:06:00Z"
        )
      }
      XCTAssertEqual(recovered.map(\.requestID), ["unary-interrupted"])
      XCTAssertEqual(recovered.first?.status, .error)
      XCTAssertEqual(try repository.load("unary-interrupted")?.status, .error)
      XCTAssertEqual(
        try repository.loadIdempotency(subjectID: "owner", idempotencyKey: "unary-key")?.status,
        .error
      )
      XCTAssertEqual(try repository.load("stream-active")?.status, .accepted)
      XCTAssertEqual(
        try repository.loadIdempotency(subjectID: "owner", idempotencyKey: "stream-key")?.status,
        .accepted
      )
      XCTAssertTrue(try repository.interruptedUnaryRequests().isEmpty)
    }
  }

  func testInvalidInputsAndExpiredIdempotencyAreRejectedWithoutDeletion() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store, now: date("2026-08-02T20:30:00Z"))
      XCTAssertThrowsError(
        try repository.record(
          ControlRequestSubmission(
            request: request(id: "bad\nrequest"), idempotencyExpiresAt: nil)))
      XCTAssertThrowsError(
        try repository.record(
          ControlRequestSubmission(
            request: request(id: "bad-digest", digestCharacter: "A"), idempotencyExpiresAt: nil)))
      XCTAssertThrowsError(
        try repository.record(
          ControlRequestSubmission(
            request: request(id: "initial-completed", status: .completed), idempotencyExpiresAt: nil
          )))
      XCTAssertThrowsError(
        try repository.record(
          ControlRequestSubmission(
            request: request(id: "expired", key: "expired-key"),
            idempotencyExpiresAt: createdAt)))

      let valid = ControlRequestSubmission(
        request: request(id: "expired-first", key: "expired-key"), idempotencyExpiresAt: expiresAt)
      XCTAssertEqual(try repository.record(valid), valid.request)
      let expiredRepository = makeRepository(store, now: date("2026-08-02T21:00:00Z"))
      XCTAssertThrowsError(
        try expiredRepository.record(
          ControlRequestSubmission(
            request: request(id: "expired-second", key: "expired-key"),
            idempotencyExpiresAt: "2026-08-02T22:00:00Z")))
      XCTAssertEqual(
        try expiredRepository.loadIdempotency(subjectID: "owner", idempotencyKey: "expired-key")?
          .requestID,
        "expired-first")
    }
  }

  func testStreamOperationCreatesRequestAndPlannedLedgerAtomicallyThenRetriesBeforeStart() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let submission = ControlRequestSubmission(
        request: request(
          id: "stream-request", key: "stream-key", operationReference: "stream-operation"),
        idempotencyExpiresAt: expiresAt
      )

      XCTAssertEqual(
        try repository.beginStreamOperation(
          submission, operationReference: "stream-operation", plannedActionType: "stream.exec"),
        .created
      )
      XCTAssertEqual(
        try repository.load("stream-request"),
        submission.request
      )
      XCTAssertEqual(
        try store.operations.loadAll(),
        [
          OperationRecord(
            id: "stream-operation", createdAt: createdAt, updatedAt: updatedAt,
            plannedActionType: "stream.exec", projectID: nil, serviceName: nil, status: .planned,
            idempotencyKey: "stream-key",
            planHash: String(repeating: "a", count: 64), payloadJSONRedacted: "{}")
        ]
      )
      XCTAssertEqual(
        try repository.beginStreamOperation(
          submission, operationReference: "stream-operation", plannedActionType: "stream.exec"),
        .retryNeverStarted
      )
    }
  }

  func testExpiredStreamIdempotencyIsAStableConflict() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let submission = ControlRequestSubmission(
        request: request(
          id: "expired-stream-request", key: "expired-stream-key",
          operationReference: "expired-stream-operation"),
        idempotencyExpiresAt: expiresAt
      )
      _ = try makeRepository(store).beginStreamOperation(
        submission,
        operationReference: "expired-stream-operation",
        plannedActionType: "stream.exec"
      )
      let expired = makeRepository(store, now: date("2026-08-02T21:00:01Z"))
      XCTAssertThrowsError(
        try expired.beginStreamOperation(
          submission,
          operationReference: "expired-stream-operation",
          plannedActionType: "stream.exec"
        )
      ) { error in
        XCTAssertEqual(error as? ControlRequestRepositoryError, .idempotencyConflict)
      }
    }
  }

  func testStartedStreamReplayIsAmbiguousAndNeverStartsAgain() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let submission = ControlRequestSubmission(
        request: request(
          id: "started-request", key: "started-key", operationReference: "started-operation"),
        idempotencyExpiresAt: expiresAt
      )
      _ = try repository.beginStreamOperation(
        submission, operationReference: "started-operation", plannedActionType: "stream.attach")
      try repository.markStreamOperationStarted(
        requestID: "started-request", operationReference: "started-operation",
        updatedAt: "2026-08-02T20:01:30Z")

      XCTAssertEqual(
        try repository.beginStreamOperation(
          submission, operationReference: "started-operation", plannedActionType: "stream.attach"),
        .ambiguousStarted
      )
      XCTAssertEqual(try store.operations.loadAll().first?.status, .recorded)
      XCTAssertEqual(try repository.load("started-request")?.status, .accepted)
    }
  }

  func testStreamOperationPersistsSuccessAndFailureTerminalStates() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)

      for (requestID, key, operation, succeeds, expected) in [
        ("success-request", "success-key", "success-operation", true, ControlRequestStatus.completed),
        ("failure-request", "failure-key", "failure-operation", false, ControlRequestStatus.error),
      ] {
        let submission = ControlRequestSubmission(
          request: request(id: requestID, key: key, operationReference: operation),
          idempotencyExpiresAt: expiresAt
        )
        _ = try repository.beginStreamOperation(
          submission, operationReference: operation, plannedActionType: "stream.exec")
        try repository.markStreamOperationStarted(
          requestID: requestID, operationReference: operation, updatedAt: "2026-08-02T20:01:30Z")
        try repository.finishStreamOperation(
          requestID: requestID, operationReference: operation, succeeded: succeeds,
          updatedAt: "2026-08-02T20:02:00Z")

        XCTAssertEqual(try repository.load(requestID)?.status, expected)
        XCTAssertEqual(try repository.loadIdempotency(subjectID: "owner", idempotencyKey: key)?.status, expected)
        XCTAssertEqual(try store.operations.loadAll().first(where: { $0.id == operation })?.status,
                       succeeds ? .succeeded : .failed)
        XCTAssertEqual(
          try repository.beginStreamOperation(
            submission, operationReference: operation, plannedActionType: "stream.exec"),
          .terminal(expected)
        )
      }
    }
  }

  func testStreamOperationRejectsCompetingRequestDigestAndOperationIdentity() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let original = ControlRequestSubmission(
        request: request(id: "competing-request", key: "competing-key", operationReference: "operation-a"),
        idempotencyExpiresAt: expiresAt
      )
      _ = try repository.beginStreamOperation(
        original, operationReference: "operation-a", plannedActionType: "stream.exec")

      let competingDigest = ControlRequestSubmission(
        request: request(
          id: "competing-request", key: "competing-key", digestCharacter: "b",
          operationReference: "operation-a"),
        idempotencyExpiresAt: expiresAt
      )
      XCTAssertThrowsError(
        try repository.beginStreamOperation(
          competingDigest, operationReference: "operation-a", plannedActionType: "stream.exec"))
      XCTAssertThrowsError(
        try repository.beginStreamOperation(
          original, operationReference: "operation-b", plannedActionType: "stream.exec"))
      XCTAssertEqual(try store.operations.loadAll().map(\.id), ["operation-a"])
      XCTAssertEqual(try repository.load("competing-request"), original.request)
    }
  }

  func testOperationWatchReceivesPlannedStartedCancelAndTerminalLifecycleInOrder() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let submission = ControlRequestSubmission(
        request: request(
          id: "watch-request", key: "watch-key", operationReference: "watch-operation"),
        idempotencyExpiresAt: expiresAt
      )

      _ = try repository.beginStreamOperation(
        submission, operationReference: "watch-operation", plannedActionType: "stream.exec",
        serviceName: "api")
      try repository.markStreamOperationStarted(
        requestID: "watch-request", operationReference: "watch-operation",
        updatedAt: "2026-08-02T20:01:30Z")
      try repository.recordStreamOperationCancelRequested(
        operationReference: "watch-operation", updatedAt: "2026-08-02T20:01:45Z")
      try repository.finishStreamOperation(
        requestID: "watch-request", operationReference: "watch-operation", succeeded: true,
        updatedAt: "2026-08-02T20:02:00Z")

      let page = try store.events.streamPage(
        after: nil,
        filter: HostwrightEventStreamFilter(serviceName: "api"),
        pageSize: 10
      )
      XCTAssertEqual(page.status, .ready)
      XCTAssertEqual(
        page.events.map { $0.event.type },
        [
          "operation.stream.planned",
          "operation.stream.started",
          "operation.stream.cancel-requested",
          "operation.stream.completed",
        ]
      )
      XCTAssertTrue(page.events.allSatisfy { $0.operationReferences == ["watch-operation"] })
      XCTAssertEqual(try store.operations.loadAll().first?.status, .succeeded)
      XCTAssertEqual(try repository.load("watch-request")?.status, .completed)
    }
  }

  func testPlannedStreamCancellationIsAtomicAndNeverMarksStarted() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let submission = ControlRequestSubmission(
        request: request(
          id: "planned-cancel-request", key: "planned-cancel-key",
          operationReference: "planned-cancel-operation"),
        idempotencyExpiresAt: expiresAt
      )
      _ = try repository.beginStreamOperation(
        submission,
        operationReference: "planned-cancel-operation",
        plannedActionType: "stream.exec"
      )
      try repository.cancelPlannedStreamOperation(
        requestID: "planned-cancel-request",
        operationReference: "planned-cancel-operation",
        updatedAt: "2026-08-02T20:01:30Z"
      )

      XCTAssertEqual(try repository.load("planned-cancel-request")?.status, .error)
      XCTAssertEqual(try store.operations.loadAll().first?.status, .abandoned)
      let lifecycle = try store.events.loadAll().filter {
        $0.source == "hostwrightd-control"
      }
      XCTAssertEqual(
        lifecycle.map(\.type),
        ["operation.stream.planned", "operation.stream.cancel-requested", "operation.stream.cancelled"]
      )
      XCTAssertFalse(lifecycle.contains { $0.type == "operation.stream.started" })
    }
  }

  func testOperationEventPayloadEscapesHostilePrintableReference() throws {
    try withStore { store in
      try bootstrapOwner(in: store)
      let repository = makeRepository(store)
      let hostile = "operation-\"},\"stage\":\"forged"
      let submission = ControlRequestSubmission(
        request: request(
          id: "escaped-event-request", key: "escaped-event-key",
          operationReference: hostile),
        idempotencyExpiresAt: expiresAt
      )
      _ = try repository.beginStreamOperation(
        submission,
        operationReference: hostile,
        plannedActionType: "stream.exec"
      )
      let event = try XCTUnwrap(store.events.loadAll().first)
      let data = try XCTUnwrap(event.payloadJSONRedacted.data(using: .utf8))
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: data) as? [String: String])
      XCTAssertEqual(object, ["operationID": hostile, "stage": "planned"])
    }
  }

  private func request(
    id: String,
    subject: String = "owner",
    key: String? = nil,
    digestCharacter: Character = "a",
    status: ControlRequestStatus = .accepted,
    operationReference: String? = nil
  ) -> ControlRequestRecord {
    ControlRequestRecord(
      requestID: id, subjectID: subject, idempotencyKey: key,
      requestDigestSHA256: String(repeating: String(digestCharacter), count: 64),
      status: status, operationReference: operationReference, createdAt: createdAt, updatedAt: updatedAt)
  }

  private func identity(subjectID: String, declaredBy: String, hash: Character)
    -> ControlPeerIdentityRecord
  {
    ControlPeerIdentityRecord(
      subjectID: subjectID, userID: 501,
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright",
        codeDirectoryHash: String(repeating: String(hash), count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: declaredBy, declaredAt: createdAt, updatedAt: updatedAt)
  }

  private func bootstrapOwner(in store: SQLiteStateStore) throws {
    try store.controlIdentities.bootstrap(
      identity(subjectID: "owner", declaredBy: "owner", hash: "a"))
  }

  private func makeRepository(
    _ store: SQLiteStateStore,
    now: Date? = nil
  ) -> ControlRequestRepository {
    let fixed = now ?? date("2026-08-02T20:30:00Z")
    return ControlRequestRepository(store: store, now: { fixed })
  }

  private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try body(store)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-control-requests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return root
  }

  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }
}
