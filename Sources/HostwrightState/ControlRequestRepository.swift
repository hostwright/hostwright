import Foundation
import HostwrightControlPlane

public enum ControlRequestStatus: String, Codable, CaseIterable, Sendable {
  case accepted
  case completed
  case rejected
  case error
}

public struct ControlRequestRecord: Codable, Equatable, Sendable {
  public let requestID: String
  public let subjectID: String
  public let idempotencyKey: String?
  public let requestDigestSHA256: String
  public let status: ControlRequestStatus
  public let operationReference: String?
  public let responseCanonicalJSON: Data?
  public let createdAt: String
  public let updatedAt: String

  public init(
    requestID: String,
    subjectID: String,
    idempotencyKey: String? = nil,
    requestDigestSHA256: String,
    status: ControlRequestStatus,
    operationReference: String? = nil,
    responseCanonicalJSON: Data? = nil,
    createdAt: String,
    updatedAt: String
  ) {
    self.requestID = requestID
    self.subjectID = subjectID
    self.idempotencyKey = idempotencyKey
    self.requestDigestSHA256 = requestDigestSHA256
    self.status = status
    self.operationReference = operationReference
    self.responseCanonicalJSON = responseCanonicalJSON
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func validateForInitialRecord() throws {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.optionalIdempotencyKey(idempotencyKey)
    try ControlRequestValidation.digest(requestDigestSHA256)
    try ControlRequestValidation.optionalOperationReference(operationReference)
    try ControlRequestValidation.optionalResponse(
      responseCanonicalJSON, requestID: requestID, status: status,
      operationReference: operationReference)
    _ = try ControlRequestValidation.timestamp(createdAt, named: "request creation timestamp")
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "request update timestamp")
    guard status == .accepted || status == .rejected else {
      throw StateStoreError.invalidRecord(
        "Control requests must start accepted or rejected."
      )
    }
    guard status == .accepted || operationReference == nil else {
      throw StateStoreError.invalidRecord(
        "Rejected control requests cannot carry an operation reference."
      )
    }
    guard responseCanonicalJSON == nil else {
      throw StateStoreError.invalidRecord(
        "Initial control requests cannot carry a response.")
    }
  }
}

public struct ControlIdempotencyRecord: Codable, Equatable, Sendable {
  public let subjectID: String
  public let idempotencyKey: String
  public let requestID: String
  public let requestDigestSHA256: String
  public let status: ControlRequestStatus
  public let createdAt: String
  public let expiresAt: String

  public init(
    subjectID: String,
    idempotencyKey: String,
    requestID: String,
    requestDigestSHA256: String,
    status: ControlRequestStatus,
    createdAt: String,
    expiresAt: String
  ) {
    self.subjectID = subjectID
    self.idempotencyKey = idempotencyKey
    self.requestID = requestID
    self.requestDigestSHA256 = requestDigestSHA256
    self.status = status
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  public func validate() throws {
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.idempotencyKey(idempotencyKey)
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.digest(requestDigestSHA256)
    let created = try ControlRequestValidation.timestamp(
      createdAt, named: "idempotency creation timestamp")
    let expires = try ControlRequestValidation.timestamp(
      expiresAt, named: "idempotency expiry timestamp")
    guard expires > created else {
      throw StateStoreError.invalidRecord(
        "Idempotency expiry must follow idempotency record creation."
      )
    }
  }
}

public struct ControlRequestSubmission: Codable, Equatable, Sendable {
  public let request: ControlRequestRecord
  public let idempotencyExpiresAt: String?

  public init(request: ControlRequestRecord, idempotencyExpiresAt: String? = nil) {
    self.request = request
    self.idempotencyExpiresAt = idempotencyExpiresAt
  }

  public func validate() throws {
    try request.validateForInitialRecord()
    guard (request.idempotencyKey == nil) == (idempotencyExpiresAt == nil) else {
      throw StateStoreError.invalidRecord(
        "Idempotency expiry must be provided exactly when the request carries an idempotency key."
      )
    }
    guard let key = request.idempotencyKey, let expiresAt = idempotencyExpiresAt else { return }
    try ControlIdempotencyRecord(
      subjectID: request.subjectID,
      idempotencyKey: key,
      requestID: request.requestID,
      requestDigestSHA256: request.requestDigestSHA256,
      status: request.status,
      createdAt: request.createdAt,
      expiresAt: expiresAt
    ).validate()
  }
}

public enum ControlRequestRecordResult: Equatable, Sendable {
  case created(ControlRequestRecord)
  case replayed(ControlRequestRecord)

  public var record: ControlRequestRecord {
    switch self {
    case .created(let record), .replayed(let record): record
    }
  }
}

public enum ControlStreamOperationStartDisposition: Equatable, Sendable {
  case created
  case retryNeverStarted
  case ambiguousStarted
  case terminal(ControlRequestStatus)

  public var shouldStart: Bool {
    self == .created || self == .retryNeverStarted
  }
}

public enum ControlRequestRepositoryError: Error, Equatable, Sendable {
  case idempotencyConflict
}

extension ControlRequestRepositoryError: StateTransactionPreservedError {}

public struct ControlRequestRepository: Sendable {
  private let store: SQLiteStateStore
  private let now: @Sendable () -> Date

  public init(
    store: SQLiteStateStore,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.now = now
  }

  public func record(_ submission: ControlRequestSubmission) throws -> ControlRequestRecord {
    try recordOrReplay(submission).record
  }

  public func recordOrReplay(
    _ submission: ControlRequestSubmission
  ) throws -> ControlRequestRecordResult {
    try submission.validate()
    return try store.withValidatedConnection { connection in
      try connection.transaction { try recordOrReplay(submission, on: connection) }
    }
  }

  public func beginStreamOperation(
    _ submission: ControlRequestSubmission,
    operationReference: String,
    plannedActionType: String,
    projectID: String? = nil,
    serviceName: String? = nil
  ) throws -> ControlStreamOperationStartDisposition {
    try submission.validate()
    try ControlRequestValidation.optionalOperationReference(operationReference)
    guard let streamIdempotencyKey = submission.request.idempotencyKey,
      !operationReference.isEmpty, !plannedActionType.isEmpty,
      plannedActionType.utf8.count <= 128
    else { throw StateStoreError.invalidRecord("Stream operation identity is invalid.") }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        let result: ControlRequestRecordResult
        do {
          result = try recordOrReplay(submission, on: connection)
        } catch StateStoreError.invalidRecord(let message)
          where Self.isDurableIdentityConflict(message)
        {
          throw ControlRequestRepositoryError.idempotencyConflict
        }
        let rows = try connection.query(
          "SELECT status FROM operation_ledger WHERE id = ? LIMIT 1",
          bindings: [.text(operationReference)]
        )
        switch result {
        case .created:
          guard rows.isEmpty else {
            throw StateStoreError.transactionInvariantViolation(
              message: "A new stream request collided with an operation ledger record.")
          }
          let request = submission.request
          try connection.run(
            """
            INSERT INTO operation_ledger (
              id, created_at, updated_at, planned_action_type, project_id, service_name,
              status, idempotency_key, plan_hash, payload_json_redacted
            ) VALUES (?, ?, ?, ?, ?, ?, 'planned', ?, ?, '{}')
            """,
            bindings: [
              .text(operationReference), .text(request.createdAt), .text(request.updatedAt),
              .text(plannedActionType), controlRequestOptionalText(projectID),
              controlRequestOptionalText(serviceName), .text(streamIdempotencyKey),
              .text(request.requestDigestSHA256),
            ]
          )
          try insertStreamOperationEvent(
            operationReference: operationReference,
            stage: "planned",
            timestamp: request.createdAt,
            projectID: projectID,
            serviceName: serviceName,
            on: connection
          )
          return .created
        case .replayed(let request):
          guard rows.count == 1, let raw = rows[0].first ?? nil,
            let status = OperationStatus(rawValue: raw),
            request.operationReference == operationReference
          else {
            throw StateStoreError.transactionInvariantViolation(
              message: "A replayed stream request lost its operation lifecycle.")
          }
          switch status {
          case .planned: return .retryNeverStarted
          case .recorded: return .ambiguousStarted
          case .succeeded: return .terminal(.completed)
          case .failed, .abandoned: return .terminal(.error)
          }
        }
      }
    }
  }

  private static func isDurableIdentityConflict(_ message: String) -> Bool {
    message == "Idempotency key is already bound to a different request digest."
      || message == "Idempotency key is already bound to a different request identifier."
      || message == "Control request ID is already bound to different durable request data."
      || message == "Expired idempotency records are retained and cannot be reused."
  }

  public func markStreamOperationStarted(
    requestID: String,
    operationReference: String,
    updatedAt: String
  ) throws {
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "stream operation start timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        try connection.run(
          "UPDATE operation_ledger SET status = 'recorded', updated_at = ? WHERE id = ? AND status = 'planned'",
          bindings: [.text(updatedAt), .text(operationReference)]
        )
        let changed = try connection.query("SELECT changes()").first?.first ?? nil
        guard changed == "1", let request = try load(requestID, on: connection),
          request.status == .accepted, request.operationReference == operationReference
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Stream operation start lost exact durable authority.")
        }
        let scope = try streamOperationScope(operationReference, on: connection)
        try insertStreamOperationEvent(
          operationReference: operationReference,
          stage: "started",
          timestamp: updatedAt,
          projectID: scope.projectID,
          serviceName: scope.serviceName,
          on: connection
        )
      }
    }
  }

  public func finishStreamOperation(
    requestID: String,
    operationReference: String,
    succeeded: Bool,
    abandoned: Bool = false,
    updatedAt: String
  ) throws {
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "stream operation finish timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        let operationStatus = succeeded ? "succeeded" : (abandoned ? "abandoned" : "failed")
        try connection.run(
          "UPDATE operation_ledger SET status = ?, updated_at = ? WHERE id = ? AND status = 'recorded'",
          bindings: [.text(operationStatus), .text(updatedAt), .text(operationReference)]
        )
        let changed = try connection.query("SELECT changes()").first?.first ?? nil
        guard changed == "1" else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Stream operation terminal transition lost exact durable authority.")
        }
        let scope = try streamOperationScope(operationReference, on: connection)
        try insertStreamOperationEvent(
          operationReference: operationReference,
          stage: succeeded ? "completed" : (abandoned ? "cancelled" : "failed"),
          timestamp: updatedAt,
          projectID: scope.projectID,
          serviceName: scope.serviceName,
          on: connection
        )
        let terminalRequestStatus = succeeded
          ? ControlRequestStatus.completed : ControlRequestStatus.error
        try connection.run(
          "UPDATE control_requests SET status = ?, updated_at = ? WHERE request_id = ? AND status = 'accepted' AND operation_reference = ?",
          bindings: [
            .text(terminalRequestStatus.rawValue),
            .text(updatedAt), .text(requestID), .text(operationReference),
          ]
        )
        guard try connection.query("SELECT changes()").first?.first == "1",
          let request = try load(requestID, on: connection),
          request.status == terminalRequestStatus,
          request.operationReference == operationReference,
          let idempotencyKey = request.idempotencyKey
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Stream operation terminal request evidence lost its exact durable link.")
        }
        try connection.run(
          "UPDATE idempotency_records SET status = ? WHERE request_id = ? AND subject_id = ? AND idempotency_key = ? AND status = 'accepted'",
          bindings: [
            .text(terminalRequestStatus.rawValue), .text(requestID),
            .text(request.subjectID), .text(idempotencyKey),
          ]
        )
        guard try connection.query("SELECT changes()").first?.first == "1",
          let idempotency = try loadIdempotency(
            subjectID: request.subjectID, idempotencyKey: idempotencyKey, on: connection),
          idempotency.requestID == requestID,
          idempotency.requestDigestSHA256 == request.requestDigestSHA256,
          idempotency.status == terminalRequestStatus
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Stream operation terminal idempotency evidence lost its exact durable link.")
        }
      }
    }
  }

  public func recordStreamOperationCancelRequested(
    operationReference: String,
    updatedAt: String
  ) throws {
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "stream cancellation timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        let scope = try streamOperationScope(operationReference, on: connection)
        guard scope.status == .recorded else {
          throw StateStoreError.invalidRecord("Only a running stream operation can be cancelled.")
        }
        try insertStreamOperationEvent(
          operationReference: operationReference,
          stage: "cancel-requested",
          timestamp: updatedAt,
          projectID: scope.projectID,
          serviceName: scope.serviceName,
          on: connection
        )
      }
    }
  }

  public func cancelPlannedStreamOperation(
    requestID: String,
    operationReference: String,
    updatedAt: String
  ) throws {
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "planned stream cancellation timestamp")
    try store.withValidatedConnection { connection in
      try connection.transaction {
        let scope = try streamOperationScope(operationReference, on: connection)
        guard scope.status == .planned else {
          throw StateStoreError.invalidRecord("Only a planned stream operation can be cancelled before start.")
        }
        try insertStreamOperationEvent(
          operationReference: operationReference,
          stage: "cancel-requested",
          timestamp: updatedAt,
          projectID: scope.projectID,
          serviceName: scope.serviceName,
          on: connection
        )
        try connection.run(
          "UPDATE operation_ledger SET status = 'abandoned', updated_at = ? WHERE id = ? AND status = 'planned'",
          bindings: [.text(updatedAt), .text(operationReference)]
        )
        guard try connection.query("SELECT changes()").first?.first == "1" else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Planned stream cancellation lost operation authority.")
        }
        try insertStreamOperationEvent(
          operationReference: operationReference,
          stage: "cancelled",
          timestamp: updatedAt,
          projectID: scope.projectID,
          serviceName: scope.serviceName,
          on: connection
        )
        try connection.run(
          "UPDATE control_requests SET status = 'error', updated_at = ? WHERE request_id = ? AND status = 'accepted' AND operation_reference = ?",
          bindings: [.text(updatedAt), .text(requestID), .text(operationReference)]
        )
        guard try connection.query("SELECT changes()").first?.first == "1",
          let request = try load(requestID, on: connection),
          request.status == .error,
          request.operationReference == operationReference,
          let idempotencyKey = request.idempotencyKey
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Planned stream cancellation lost request authority.")
        }
        try connection.run(
          "UPDATE idempotency_records SET status = 'error' WHERE request_id = ? AND subject_id = ? AND idempotency_key = ? AND status = 'accepted'",
          bindings: [.text(requestID), .text(request.subjectID), .text(idempotencyKey)]
        )
        guard try connection.query("SELECT changes()").first?.first == "1",
          try loadIdempotency(
            subjectID: request.subjectID,
            idempotencyKey: idempotencyKey,
            on: connection
          )?.status == .error
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Planned stream cancellation lost idempotency authority.")
        }
      }
    }
  }

  private func streamOperationScope(
    _ operationReference: String,
    on connection: SQLiteConnection
  ) throws -> (projectID: String?, serviceName: String?, status: OperationStatus) {
    let rows = try connection.query(
      "SELECT project_id, service_name, status FROM operation_ledger WHERE id = ? LIMIT 1",
      bindings: [.text(operationReference)]
    )
    guard rows.count == 1, rows[0].count == 3, let raw = rows[0][2],
      let status = OperationStatus(rawValue: raw)
    else { throw StateStoreError.notFound("Stream operation does not exist.") }
    return (rows[0][0], rows[0][1], status)
  }

  private func insertStreamOperationEvent(
    operationReference: String,
    stage: String,
    timestamp: String,
    projectID: String?,
    serviceName: String?,
    on connection: SQLiteConnection
  ) throws {
    let payloadData: Data
    do {
      payloadData = try JSONSerialization.data(
        withJSONObject: ["operationID": operationReference, "stage": stage],
        options: [.sortedKeys, .withoutEscapingSlashes]
      )
    } catch {
      throw StateStoreError.invalidRecord("Stream operation event payload is not encodable.")
    }
    guard let payload = String(data: payloadData, encoding: .utf8) else {
      throw StateStoreError.invalidRecord("Stream operation event payload is not UTF-8.")
    }
    try connection.run(
      """
      INSERT INTO event_ledger (
        id, timestamp, severity, type, source, project_id, service_name,
        runtime_adapter, message, payload_json_redacted
      ) VALUES (?, ?, 'info', ?, 'hostwrightd-control', ?, ?, NULL, ?, ?)
      """,
      bindings: [
        .text("event-stream-\(UUID().uuidString.lowercased())"),
        .text(timestamp), .text("operation.stream.\(stage)"),
        controlRequestOptionalText(projectID), controlRequestOptionalText(serviceName),
        .text("Stream operation \(stage)."), .text(payload),
      ]
    )
  }

  private func recordOrReplay(
    _ submission: ControlRequestSubmission,
    on connection: SQLiteConnection
  ) throws -> ControlRequestRecordResult {
        if let key = submission.request.idempotencyKey {
          if let existing = try loadIdempotency(
            subjectID: submission.request.subjectID,
            idempotencyKey: key,
            on: connection
          ) {
            guard try isActive(existing) else {
              throw StateStoreError.invalidRecord(
                "Expired idempotency records are retained and cannot be reused."
              )
            }
            guard existing.requestDigestSHA256 == submission.request.requestDigestSHA256 else {
              throw StateStoreError.invalidRecord(
                "Idempotency key is already bound to a different request digest."
              )
            }
            guard let request = try load(existing.requestID, on: connection) else {
              throw StateStoreError.transactionInvariantViolation(
                message: "Idempotency record references a missing control request."
              )
            }
            guard request.requestID == submission.request.requestID else {
              throw StateStoreError.invalidRecord(
                "Idempotency key is already bound to a different request identifier."
              )
            }
            return .replayed(request)
          }
        }
        if let existing = try load(submission.request.requestID, on: connection) {
          guard existing == submission.request else {
            throw StateStoreError.invalidRecord(
              "Control request ID is already bound to different durable request data."
            )
          }
          return .replayed(existing)
        }
        try insert(submission.request, on: connection)
        if let key = submission.request.idempotencyKey,
          let expiresAt = submission.idempotencyExpiresAt
        {
          try insert(
            ControlIdempotencyRecord(
              subjectID: submission.request.subjectID,
              idempotencyKey: key,
              requestID: submission.request.requestID,
              requestDigestSHA256: submission.request.requestDigestSHA256,
              status: submission.request.status,
              createdAt: submission.request.createdAt,
              expiresAt: expiresAt
            ),
            on: connection
          )
        }
        return .created(submission.request)
  }

  public func updateTerminal(
    requestID: String,
    status: ControlRequestStatus,
    operationReference: String?,
    responseCanonicalJSON: Data? = nil,
    updatedAt: String
  ) throws -> ControlRequestRecord {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.optionalOperationReference(operationReference)
    try ControlRequestValidation.optionalResponse(
      responseCanonicalJSON, requestID: requestID, status: status,
      operationReference: operationReference)
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "request update timestamp")
    guard status == .completed || status == .rejected || status == .error else {
      throw StateStoreError.invalidRecord(
        "Control request updates may transition only to completed, rejected, or error."
      )
    }
    guard status != .rejected || operationReference == nil else {
      throw StateStoreError.invalidRecord(
        "Rejected control requests cannot carry an operation reference."
      )
    }
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try load(requestID, on: connection) else {
          throw StateStoreError.notFound("Control request \(requestID) does not exist.")
        }
        guard existing.status == .accepted else {
          throw StateStoreError.invalidRecord(
            "Only accepted control requests may enter a terminal state."
          )
        }
        if let recorded = existing.operationReference,
          let operationReference,
          recorded != operationReference
        {
          throw StateStoreError.invalidRecord(
            "The control request cannot change its durable operation reference."
          )
        }
        let effectiveOperationReference = status == .rejected
          ? nil
          : operationReference ?? existing.operationReference
        try connection.run(
          """
          UPDATE control_requests
          SET status = ?, operation_reference = ?, response_json = ?, updated_at = ?
          WHERE request_id = ? AND status = 'accepted'
          """,
          bindings: [
            .text(status.rawValue), controlRequestOptionalText(effectiveOperationReference),
            responseCanonicalJSON.map {
              .text(String(decoding: $0, as: UTF8.self))
            } ?? .null,
            .text(updatedAt), .text(requestID),
          ]
        )
        if existing.idempotencyKey != nil {
          try connection.run(
            "UPDATE idempotency_records SET status = ? WHERE request_id = ?",
            bindings: [.text(status.rawValue), .text(requestID)]
          )
        }
        guard let updated = try load(requestID, on: connection), updated.status == status else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Control request terminal transition did not persist."
          )
        }
        return updated
      }
    }
  }

  public func interruptedUnaryRequests() throws -> [ControlRequestRecord] {
    try store.withValidatedConnection { connection in
      try connection.query(
        """
        SELECT request_id, subject_id, idempotency_key, request_digest_sha256,
               status, operation_reference, response_json, created_at, updated_at
        FROM control_requests
        WHERE status = 'accepted' AND operation_reference LIKE 'unary:%'
        ORDER BY request_id ASC
        """
      ).map(request(from:))
    }
  }

  public func markInterruptedUnaryRequest(
    requestID: String,
    operationReference: String,
    updatedAt: String
  ) throws -> ControlRequestRecord {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.optionalOperationReference(operationReference)
    guard operationReference.hasPrefix("unary:") else {
      throw StateStoreError.invalidRecord(
        "Only durable unary operations may use restart recovery."
      )
    }
    _ = try ControlRequestValidation.timestamp(
      updatedAt,
      named: "request recovery timestamp"
    )
    guard let record = try load(requestID),
      record.status == .accepted,
      record.operationReference == operationReference
    else {
      throw StateStoreError.invalidRecord(
        "Interrupted unary recovery no longer matches the accepted request."
      )
    }
    return try updateTerminal(
      requestID: requestID,
      status: .error,
      operationReference: operationReference,
      updatedAt: updatedAt
    )
  }

  public func recordAcceptedOperationReference(
    requestID: String,
    operationReference: String,
    responseCanonicalJSON: Data? = nil,
    updatedAt: String
  ) throws -> ControlRequestRecord {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.optionalOperationReference(operationReference)
    try ControlRequestValidation.optionalResponse(
      responseCanonicalJSON, requestID: requestID, status: .accepted,
      operationReference: operationReference)
    guard !operationReference.isEmpty else {
      throw StateStoreError.invalidRecord("Accepted operation references cannot be empty.")
    }
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "request update timestamp")
    return try store.withValidatedConnection { connection in
      try connection.transaction {
        guard let existing = try load(requestID, on: connection) else {
          throw StateStoreError.notFound("Control request \(requestID) does not exist.")
        }
        guard existing.status == .accepted else {
          throw StateStoreError.invalidRecord(
            "Only accepted control requests may bind an operation reference."
          )
        }
        if let recorded = existing.operationReference {
          guard recorded == operationReference else {
            throw StateStoreError.invalidRecord(
              "The control request is already bound to a different operation reference."
            )
          }
          if let responseCanonicalJSON, let recordedResponse = existing.responseCanonicalJSON,
            responseCanonicalJSON != recordedResponse
          {
            throw StateStoreError.invalidRecord(
              "The control request is already bound to a different accepted response.")
          }
          if responseCanonicalJSON == nil || existing.responseCanonicalJSON != nil {
            return existing
          }
        }
        try connection.run(
          "UPDATE control_requests SET operation_reference = ?, response_json = COALESCE(response_json, ?), updated_at = ? WHERE request_id = ? AND status = 'accepted' AND (operation_reference IS NULL OR operation_reference = ?)",
          bindings: [
            .text(operationReference), responseCanonicalJSON.map {
              .text(String(decoding: $0, as: UTF8.self))
            } ?? .null,
            .text(updatedAt), .text(requestID), .text(operationReference),
          ]
        )
        guard let updated = try load(requestID, on: connection),
          updated.status == .accepted,
          updated.operationReference == operationReference
        else {
          throw StateStoreError.transactionInvariantViolation(
            message: "Control request operation reference did not persist."
          )
        }
        return updated
      }
    }
  }

  public func recordRejectedConflict(_ record: ControlRequestRecord) throws {
    try record.validateForInitialRecord()
    guard record.status == .rejected, record.operationReference == nil else {
      throw StateStoreError.invalidRecord(
        "A durable control conflict must be an initial rejected request."
      )
    }
    try store.withValidatedConnection { connection in
      try connection.transaction {
        if let existing = try load(record.requestID, on: connection) {
          guard existing == record else {
            throw StateStoreError.invalidRecord(
              "Control request ID is already bound to different durable request data."
            )
          }
          return
        }
        try insert(record, on: connection)
      }
    }
  }

  public func load(_ requestID: String) throws -> ControlRequestRecord? {
    try ControlRequestValidation.requestID(requestID)
    return try store.withValidatedConnection(readOnly: true) { connection in
      try load(requestID, on: connection)
    }
  }

  public func load(subjectID: String, idempotencyKey: String) throws -> ControlRequestRecord? {
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.idempotencyKey(idempotencyKey)
    return try store.withValidatedConnection(readOnly: true) { connection in
      guard
        let idempotency = try loadIdempotency(
          subjectID: subjectID,
          idempotencyKey: idempotencyKey,
          on: connection
        )
      else {
        return nil
      }
      return try load(idempotency.requestID, on: connection)
    }
  }

  public func loadIdempotency(
    subjectID: String,
    idempotencyKey: String
  ) throws -> ControlIdempotencyRecord? {
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.idempotencyKey(idempotencyKey)
    return try store.withValidatedConnection(readOnly: true) { connection in
      try loadIdempotency(subjectID: subjectID, idempotencyKey: idempotencyKey, on: connection)
    }
  }

  private func isActive(_ record: ControlIdempotencyRecord) throws -> Bool {
    try ControlRequestValidation.timestamp(record.expiresAt, named: "idempotency expiry timestamp")
      > now()
  }

  private func insert(_ record: ControlRequestRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO control_requests (
        request_id, subject_id, idempotency_key, request_digest_sha256,
        status, operation_reference, response_json, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(record.requestID), .text(record.subjectID),
        controlRequestOptionalText(record.idempotencyKey), .text(record.requestDigestSHA256),
        .text(record.status.rawValue), controlRequestOptionalText(record.operationReference),
        record.responseCanonicalJSON.map {
          .text(String(decoding: $0, as: UTF8.self))
        } ?? .null,
        .text(record.createdAt), .text(record.updatedAt),
      ]
    )
  }

  private func insert(_ record: ControlIdempotencyRecord, on connection: SQLiteConnection) throws {
    try connection.run(
      """
      INSERT INTO idempotency_records (
        subject_id, idempotency_key, request_id, request_digest_sha256,
        status, created_at, expires_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(record.subjectID), .text(record.idempotencyKey), .text(record.requestID),
        .text(record.requestDigestSHA256), .text(record.status.rawValue),
        .text(record.createdAt), .text(record.expiresAt),
      ]
    )
  }

  private func load(_ requestID: String, on connection: SQLiteConnection) throws
    -> ControlRequestRecord?
  {
    let rows = try connection.query(
      """
      SELECT request_id, subject_id, idempotency_key, request_digest_sha256,
             status, operation_reference, response_json, created_at, updated_at
      FROM control_requests WHERE request_id = ? LIMIT 1
      """,
      bindings: [.text(requestID)]
    )
    return try rows.first.map(request(from:))
  }

  private func loadIdempotency(
    subjectID: String,
    idempotencyKey: String,
    on connection: SQLiteConnection
  ) throws -> ControlIdempotencyRecord? {
    let rows = try connection.query(
      """
      SELECT subject_id, idempotency_key, request_id, request_digest_sha256,
             status, created_at, expires_at
      FROM idempotency_records
      WHERE subject_id = ? AND idempotency_key = ?
      LIMIT 1
      """,
      bindings: [.text(subjectID), .text(idempotencyKey)]
    )
    return try rows.first.map(idempotency(from:))
  }

  private func request(from row: [String?]) throws -> ControlRequestRecord {
    guard row.count == 9,
      let requestID = row[0], let subjectID = row[1], let digest = row[3],
      let statusRaw = row[4], let status = ControlRequestStatus(rawValue: statusRaw),
      let createdAt = row[7], let updatedAt = row[8]
    else {
      throw StateStoreError.invalidRecord("Stored control request has an invalid shape.")
    }
    let record = ControlRequestRecord(
      requestID: requestID,
      subjectID: subjectID,
      idempotencyKey: row[2] ?? nil,
      requestDigestSHA256: digest,
      status: status,
      operationReference: row[5] ?? nil,
      responseCanonicalJSON: row[6].map { Data($0.utf8) },
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    try record.validateForStoredRecord()
    return record
  }

  private func idempotency(from row: [String?]) throws -> ControlIdempotencyRecord {
    guard row.count == 7,
      let subjectID = row[0], let key = row[1], let requestID = row[2], let digest = row[3],
      let statusRaw = row[4], let status = ControlRequestStatus(rawValue: statusRaw),
      let createdAt = row[5], let expiresAt = row[6]
    else {
      throw StateStoreError.invalidRecord("Stored idempotency record has an invalid shape.")
    }
    let record = ControlIdempotencyRecord(
      subjectID: subjectID,
      idempotencyKey: key,
      requestID: requestID,
      requestDigestSHA256: digest,
      status: status,
      createdAt: createdAt,
      expiresAt: expiresAt
    )
    try record.validate()
    return record
  }
}

extension ControlRequestRecord {
  fileprivate func validateForStoredRecord() throws {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.optionalIdempotencyKey(idempotencyKey)
    try ControlRequestValidation.digest(requestDigestSHA256)
    try ControlRequestValidation.optionalOperationReference(operationReference)
    try ControlRequestValidation.optionalResponse(
      responseCanonicalJSON, requestID: requestID, status: status,
      operationReference: operationReference)
    _ = try ControlRequestValidation.timestamp(createdAt, named: "request creation timestamp")
    _ = try ControlRequestValidation.timestamp(updatedAt, named: "request update timestamp")
    guard status != .rejected || operationReference == nil else {
      throw StateStoreError.invalidRecord(
        "Rejected control requests cannot carry an operation reference."
      )
    }
  }
}

private enum ControlRequestValidation {
  static func requestID(_ value: String) throws {
    guard safePrintable(value, maximumLength: 128) else {
      throw StateStoreError.invalidRecord(
        "Control request ID must be a canonical safe printable identifier.")
    }
  }

  static func subjectID(_ value: String) throws {
    guard safePrintable(value, maximumLength: 128) else {
      throw StateStoreError.invalidRecord(
        "Control request subject ID must match the persisted identity shape.")
    }
  }

  static func idempotencyKey(_ value: String) throws {
    guard safePrintable(value, maximumLength: 256) else {
      throw StateStoreError.invalidRecord("Idempotency key must be a bounded printable value.")
    }
  }

  static func optionalIdempotencyKey(_ value: String?) throws {
    if let value { try idempotencyKey(value) }
  }

  static func digest(_ value: String) throws {
    guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw StateStoreError.invalidRecord(
        "Control request digest must be a lowercase SHA-256 digest.")
    }
  }

  static func optionalOperationReference(_ value: String?) throws {
    if let value, !safePrintable(value, maximumLength: 128) {
      throw StateStoreError.invalidRecord("Operation reference must be a bounded printable value.")
    }
  }

  static func optionalResponse(
    _ data: Data?, requestID: String, status: ControlRequestStatus,
    operationReference: String?
  ) throws {
    guard let data else { return }
    guard (2...ControlPlaneContract.maximumResponseOrFrameBytes).contains(data.count) else {
      throw StateStoreError.invalidRecord("Stored control response exceeds its bounded size.")
    }
    let response: ControlResponseEnvelope
    do {
      response = try JSONDecoder().decode(ControlResponseEnvelope.self, from: data)
      try response.validate()
      guard try ControlPlaneCanonicalJSON.encode(response) == data else {
        throw StateStoreError.invalidRecord("Stored control response is not canonical JSON.")
      }
    } catch let error as StateStoreError {
      throw error
    } catch {
      throw StateStoreError.invalidRecord("Stored control response is invalid.")
    }
    let expectedStatus: ControlResponseStatus
    switch status {
    case .accepted: expectedStatus = .accepted
    case .completed: expectedStatus = .completed
    case .rejected: expectedStatus = .rejected
    case .error: expectedStatus = .error
    }
    guard response.requestID == requestID, response.status == expectedStatus,
      response.operationRef == operationReference
    else {
      throw StateStoreError.invalidRecord(
        "Stored control response does not match its durable request.")
    }
  }

  static func timestamp(_ value: String, named: String) throws -> Date {
    guard value.utf8.count <= 64, value.hasSuffix("Z"),
      let date = ISO8601DateFormatter().date(from: value)
    else {
      throw StateStoreError.invalidRecord("\(named) must be ISO-8601 UTC text.")
    }
    return date
  }

  private static func safePrintable(_ value: String, maximumLength: Int) -> Bool {
    guard !value.isEmpty, value.utf8.count <= maximumLength else { return false }
    return value.unicodeScalars.allSatisfy { scalar in
      scalar.value >= 0x20 && scalar.value <= 0x7E
    }
  }
}

private func controlRequestOptionalText(_ value: String?) -> SQLiteValue {
  value.map(SQLiteValue.text) ?? .null
}
