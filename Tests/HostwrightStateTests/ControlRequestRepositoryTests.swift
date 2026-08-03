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

  private func request(
    id: String,
    subject: String = "owner",
    key: String? = nil,
    digestCharacter: Character = "a",
    status: ControlRequestStatus = .accepted
  ) -> ControlRequestRecord {
    ControlRequestRecord(
      requestID: id, subjectID: subject, idempotencyKey: key,
      requestDigestSHA256: String(repeating: String(digestCharacter), count: 64),
      status: status, createdAt: createdAt, updatedAt: updatedAt)
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
