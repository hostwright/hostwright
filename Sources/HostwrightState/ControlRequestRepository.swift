import Foundation

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
  public let createdAt: String
  public let updatedAt: String

  public init(
    requestID: String,
    subjectID: String,
    idempotencyKey: String? = nil,
    requestDigestSHA256: String,
    status: ControlRequestStatus,
    operationReference: String? = nil,
    createdAt: String,
    updatedAt: String
  ) {
    self.requestID = requestID
    self.subjectID = subjectID
    self.idempotencyKey = idempotencyKey
    self.requestDigestSHA256 = requestDigestSHA256
    self.status = status
    self.operationReference = operationReference
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public func validateForInitialRecord() throws {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.subjectID(subjectID)
    try ControlRequestValidation.optionalIdempotencyKey(idempotencyKey)
    try ControlRequestValidation.digest(requestDigestSHA256)
    try ControlRequestValidation.optionalOperationReference(operationReference)
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
      try connection.transaction {
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
    }
  }

  public func updateTerminal(
    requestID: String,
    status: ControlRequestStatus,
    operationReference: String?,
    updatedAt: String
  ) throws -> ControlRequestRecord {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.optionalOperationReference(operationReference)
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
          SET status = ?, operation_reference = ?, updated_at = ?
          WHERE request_id = ? AND status = 'accepted'
          """,
          bindings: [
            .text(status.rawValue), controlRequestOptionalText(effectiveOperationReference),
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

  public func recordAcceptedOperationReference(
    requestID: String,
    operationReference: String,
    updatedAt: String
  ) throws -> ControlRequestRecord {
    try ControlRequestValidation.requestID(requestID)
    try ControlRequestValidation.optionalOperationReference(operationReference)
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
          return existing
        }
        try connection.run(
          "UPDATE control_requests SET operation_reference = ?, updated_at = ? WHERE request_id = ? AND status = 'accepted' AND operation_reference IS NULL",
          bindings: [.text(operationReference), .text(updatedAt), .text(requestID)]
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
        status, operation_reference, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """,
      bindings: [
        .text(record.requestID), .text(record.subjectID),
        controlRequestOptionalText(record.idempotencyKey), .text(record.requestDigestSHA256),
        .text(record.status.rawValue), controlRequestOptionalText(record.operationReference),
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
             status, operation_reference, created_at, updated_at
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
    guard row.count == 8,
      let requestID = row[0], let subjectID = row[1], let digest = row[3],
      let statusRaw = row[4], let status = ControlRequestStatus(rawValue: statusRaw),
      let createdAt = row[6], let updatedAt = row[7]
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
