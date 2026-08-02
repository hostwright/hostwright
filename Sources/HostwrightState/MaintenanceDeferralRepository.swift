import CryptoKit
import Foundation
import HostwrightManifest
import HostwrightRuntime

public enum MaintenanceDeferralState: String, Codable, Equatable, Sendable {
    case deferred
    case cancelled
    case overrideAuthorized = "override-authorized"
    case admitted
    case failed
    case superseded
}

public struct MaintenanceDeferralRecord: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let projectID: String
    public let planSHA256: String
    public let policySHA256: String
    public let actionClasses: [HostwrightMaintenanceActionClass]
    public let confirmationToken: String
    public let state: MaintenanceDeferralState
    public let firstDeferredAt: String
    public let deadlineAt: String
    public let updatedAt: String
    public let windowID: String?
    public let reasonRedacted: String?

    public init(
        projectID: String,
        planSHA256: String,
        policySHA256: String,
        actionClasses: [HostwrightMaintenanceActionClass],
        confirmationToken: String,
        state: MaintenanceDeferralState,
        firstDeferredAt: String,
        deadlineAt: String,
        updatedAt: String,
        windowID: String? = nil,
        reasonRedacted: String? = nil
    ) throws {
        let normalizedActions = actionClasses.sorted { $0.rawValue < $1.rawValue }
        guard let firstDeferredDate = Self.canonicalDate(firstDeferredAt),
              let deadlineDate = Self.canonicalDate(deadlineAt),
              Self.canonicalDate(updatedAt) != nil,
              projectID.range(of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$", options: .regularExpression) != nil,
              Self.isSHA256(planSHA256),
              Self.isSHA256(policySHA256),
              Self.isSHA256(confirmationToken),
              !normalizedActions.isEmpty,
              Set(normalizedActions).count == normalizedActions.count,
              normalizedActions.allSatisfy(\.isElective),
              firstDeferredDate <= deadlineDate,
              confirmationToken == Self.confirmationToken(
                projectID: projectID,
                planSHA256: planSHA256,
                policySHA256: policySHA256,
                actionClasses: normalizedActions,
                firstDeferredAt: firstDeferredAt
              ),
              windowID.map({ $0.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil }) ?? true,
              reasonRedacted.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else {
            throw StateStoreError.invalidRecord("Maintenance deferral record fields are invalid or unbounded.")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.projectID = projectID
        self.planSHA256 = planSHA256
        self.policySHA256 = policySHA256
        self.actionClasses = normalizedActions
        self.confirmationToken = confirmationToken
        self.state = state
        self.firstDeferredAt = firstDeferredAt
        self.deadlineAt = deadlineAt
        self.updatedAt = updatedAt
        self.windowID = windowID
        self.reasonRedacted = reasonRedacted.map { RuntimeRedactionPolicy.default.redact($0) }
    }

    public static func confirmationToken(
        projectID: String,
        planSHA256: String,
        policySHA256: String,
        actionClasses: [HostwrightMaintenanceActionClass],
        firstDeferredAt: String
    ) -> String {
        let material = [
            "maintenance-deferral-v1",
            projectID,
            planSHA256,
            policySHA256,
            actionClasses.map(\.rawValue).sorted().joined(separator: ","),
            firstDeferredAt
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    fileprivate static func canonicalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return date
    }

    fileprivate static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

public struct MaintenanceDeferralRepository: Sendable {
    public static let plannedActionType = "maintenance.deferral"

    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func latest(projectID: String) throws -> MaintenanceDeferralRecord? {
        try validateProjectID(projectID)
        return try store.withValidatedConnection(readOnly: true) { connection in
            try latest(projectID: projectID, on: connection)
        }
    }

    public func history(projectID: String? = nil) throws -> [MaintenanceDeferralRecord] {
        if let projectID { try validateProjectID(projectID) }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let rows: [[String?]]
            if let projectID {
                rows = try connection.query(
                    """
                    SELECT payload_json_redacted
                    FROM operation_ledger
                    WHERE planned_action_type = ? AND idempotency_key GLOB ?
                    ORDER BY created_at ASC, rowid ASC
                    """,
                    bindings: [.text(Self.plannedActionType), .text("maintenance:\(projectID):*")]
                )
            } else {
                rows = try connection.query(
                    """
                    SELECT payload_json_redacted
                    FROM operation_ledger
                    WHERE planned_action_type = ?
                    ORDER BY created_at ASC, rowid ASC
                    """,
                    bindings: [.text(Self.plannedActionType)]
                )
            }
            return try rows.map { row in
                guard let payload = row.first ?? nil else {
                    throw StateStoreError.invalidRecord("Maintenance deferral history payload is missing.")
                }
                return try decode(payload)
            }
        }
    }

    public func deferPlan(
        projectID: String,
        planSHA256: String,
        policySHA256: String,
        actionClasses: [HostwrightMaintenanceActionClass],
        firstDeferredAt: String,
        deadlineAt: String,
        reasonRedacted: String
    ) throws -> MaintenanceDeferralRecord {
        let token = MaintenanceDeferralRecord.confirmationToken(
            projectID: projectID,
            planSHA256: planSHA256,
            policySHA256: policySHA256,
            actionClasses: actionClasses,
            firstDeferredAt: firstDeferredAt
        )
        let pending = try MaintenanceDeferralRecord(
            projectID: projectID,
            planSHA256: planSHA256,
            policySHA256: policySHA256,
            actionClasses: actionClasses,
            confirmationToken: token,
            state: .deferred,
            firstDeferredAt: firstDeferredAt,
            deadlineAt: deadlineAt,
            updatedAt: firstDeferredAt,
            reasonRedacted: reasonRedacted
        )
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                if let current = try latest(projectID: projectID, on: connection) {
                    if current.planSHA256 == planSHA256,
                       current.policySHA256 == policySHA256,
                       current.actionClasses == pending.actionClasses,
                       [.deferred, .cancelled, .overrideAuthorized].contains(current.state) {
                        return current
                    }
                    if current.state == .deferred || current.state == .overrideAuthorized {
                        let superseded = try transitioned(
                            current,
                            state: .superseded,
                            updatedAt: firstDeferredAt,
                            windowID: nil,
                            reasonRedacted: "A newer validated maintenance plan superseded this pending plan."
                        )
                        try insert(superseded, on: connection)
                    }
                }
                try insert(pending, on: connection)
                return pending
            }
        }
    }

    public func cancel(
        projectID: String,
        expectedConfirmationToken: String,
        updatedAt: String
    ) throws -> MaintenanceDeferralRecord? {
        try transition(
            projectID: projectID,
            expectedConfirmationToken: expectedConfirmationToken,
            allowedStates: [.deferred, .overrideAuthorized],
            state: .cancelled,
            updatedAt: updatedAt,
            windowID: nil,
            reasonRedacted: "The exact deferred maintenance plan was cancelled locally."
        )
    }

    public func authorizeOverride(
        projectID: String,
        expectedConfirmationToken: String,
        reasonRedacted: String,
        updatedAt: String
    ) throws -> MaintenanceDeferralRecord? {
        try transition(
            projectID: projectID,
            expectedConfirmationToken: expectedConfirmationToken,
            allowedStates: [.deferred],
            state: .overrideAuthorized,
            updatedAt: updatedAt,
            windowID: nil,
            reasonRedacted: reasonRedacted
        )
    }

    public func supersede(
        projectID: String,
        expectedConfirmationToken: String,
        updatedAt: String
    ) throws -> MaintenanceDeferralRecord? {
        try transition(
            projectID: projectID,
            expectedConfirmationToken: expectedConfirmationToken,
            allowedStates: [.deferred, .overrideAuthorized],
            state: .superseded,
            updatedAt: updatedAt,
            windowID: nil,
            reasonRedacted: "A newer validated maintenance plan superseded this pending plan."
        )
    }

    public func recordAdmission(
        projectID: String,
        expectedConfirmationToken: String,
        state: MaintenanceDeferralState,
        windowID: String?,
        reasonRedacted: String,
        updatedAt: String
    ) throws -> MaintenanceDeferralRecord? {
        guard state == .admitted || state == .failed else {
            throw StateStoreError.invalidRecord("Maintenance admission must record admitted or failed.")
        }
        return try transition(
            projectID: projectID,
            expectedConfirmationToken: expectedConfirmationToken,
            allowedStates: [.deferred, .overrideAuthorized],
            state: state,
            updatedAt: updatedAt,
            windowID: windowID,
            reasonRedacted: reasonRedacted
        )
    }

    private func transition(
        projectID: String,
        expectedConfirmationToken: String,
        allowedStates: Set<MaintenanceDeferralState>,
        state: MaintenanceDeferralState,
        updatedAt: String,
        windowID: String?,
        reasonRedacted: String
    ) throws -> MaintenanceDeferralRecord? {
        try validateProjectID(projectID)
        guard MaintenanceDeferralRecord.isSHA256(expectedConfirmationToken) else {
            throw StateStoreError.invalidRecord("Maintenance transition requires an exact SHA-256 confirmation token.")
        }
        return try store.withValidatedConnection { connection in
            try connection.transaction {
                guard let current = try latest(projectID: projectID, on: connection),
                      current.confirmationToken == expectedConfirmationToken,
                      allowedStates.contains(current.state) else { return nil }
                let next = try transitioned(
                    current,
                    state: state,
                    updatedAt: updatedAt,
                    windowID: windowID,
                    reasonRedacted: reasonRedacted
                )
                try insert(next, on: connection)
                return next
            }
        }
    }

    private func latest(
        projectID: String,
        on connection: SQLiteConnection
    ) throws -> MaintenanceDeferralRecord? {
        let rows = try connection.query(
            """
            SELECT payload_json_redacted
            FROM operation_ledger
            WHERE planned_action_type = ? AND idempotency_key GLOB ?
            ORDER BY rowid DESC
            LIMIT 1
            """,
            bindings: [.text(Self.plannedActionType), .text("maintenance:\(projectID):*")]
        )
        guard let payload = rows.first?.first ?? nil else { return nil }
        return try decode(payload)
    }

    private func transitioned(
        _ current: MaintenanceDeferralRecord,
        state: MaintenanceDeferralState,
        updatedAt: String,
        windowID: String?,
        reasonRedacted: String
    ) throws -> MaintenanceDeferralRecord {
        try MaintenanceDeferralRecord(
            projectID: current.projectID,
            planSHA256: current.planSHA256,
            policySHA256: current.policySHA256,
            actionClasses: current.actionClasses,
            confirmationToken: current.confirmationToken,
            state: state,
            firstDeferredAt: current.firstDeferredAt,
            deadlineAt: current.deadlineAt,
            updatedAt: updatedAt,
            windowID: windowID,
            reasonRedacted: reasonRedacted
        )
    }

    private func insert(
        _ record: MaintenanceDeferralRecord,
        on connection: SQLiteConnection
    ) throws {
        let payload = try encode(record)
        let projectExists = !(try connection.query(
            "SELECT 1 FROM projects WHERE id = ? LIMIT 1",
            bindings: [.text(record.projectID)]
        )).isEmpty
        try connection.run(
            """
            INSERT INTO operation_ledger (
                id, created_at, updated_at, planned_action_type, project_id, service_name,
                status, idempotency_key, plan_hash, payload_json_redacted
            ) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)
            """,
            bindings: [
                .text(UUID().uuidString.lowercased()),
                .text(record.updatedAt),
                .text(record.updatedAt),
                .text(Self.plannedActionType),
                projectExists ? .text(record.projectID) : .null,
                .text(operationStatus(record.state).rawValue),
                .text("maintenance:\(record.projectID):\(record.planSHA256)"),
                .text(record.planSHA256),
                .text(payload)
            ]
        )
    }

    private func operationStatus(_ state: MaintenanceDeferralState) -> OperationStatus {
        switch state {
        case .deferred: .planned
        case .overrideAuthorized: .recorded
        case .admitted: .succeeded
        case .failed: .failed
        case .cancelled, .superseded: .abandoned
        }
    }

    private func encode(_ record: MaintenanceDeferralRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard let value = String(data: data, encoding: .utf8) else {
            throw StateStoreError.invalidRecord("Maintenance deferral JSON encoding failed.")
        }
        return try StateJSON.redactedJSON(value)
    }

    private func decode(_ payload: String) throws -> MaintenanceDeferralRecord {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(MaintenanceDeferralRecord.self, from: data),
              decoded.schemaVersion == MaintenanceDeferralRecord.currentSchemaVersion else {
            throw StateStoreError.invalidRecord("Maintenance deferral payload is invalid or unsupported.")
        }
        return try MaintenanceDeferralRecord(
            projectID: decoded.projectID,
            planSHA256: decoded.planSHA256,
            policySHA256: decoded.policySHA256,
            actionClasses: decoded.actionClasses,
            confirmationToken: decoded.confirmationToken,
            state: decoded.state,
            firstDeferredAt: decoded.firstDeferredAt,
            deadlineAt: decoded.deadlineAt,
            updatedAt: decoded.updatedAt,
            windowID: decoded.windowID,
            reasonRedacted: decoded.reasonRedacted
        )
    }

    private func validateProjectID(_ projectID: String) throws {
        guard projectID.range(of: "^project-[A-Za-z0-9](?:[A-Za-z0-9._-]{0,126}[A-Za-z0-9])?$", options: .regularExpression) != nil else {
            throw StateStoreError.invalidRecord("Maintenance deferral requires an exact bounded project ID.")
        }
    }
}
