import Crypto
import Foundation

public enum HostwrightEventStreamError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidCursor
    case cursorIntegrityMismatch
    case invalidFilter(String)
    case cancelled

    public var code: String {
        switch self {
        case .invalidCursor: "HW-EVENT-001"
        case .cursorIntegrityMismatch: "HW-EVENT-002"
        case .invalidFilter: "HW-EVENT-003"
        case .cancelled: "HW-EVENT-004"
        }
    }

    public var description: String {
        switch self {
        case .invalidCursor:
            "\(code): The event cursor is invalid."
        case .cursorIntegrityMismatch:
            "\(code): The retained cursor event no longer matches its immutable reference."
        case .invalidFilter(let message):
            "\(code): \(message)"
        case .cancelled:
            "\(code): The local event watch was cancelled."
        }
    }
}

public struct HostwrightEventCursor: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let beginning = "beginning"
    public static let maximumTokenBytes = 1_024
    private static let prefix = "hwe1."

    public let eventID: String
    public let eventSHA256: String

    public init(eventID: String, eventSHA256: String) throws {
        guard Self.validEventID(eventID), Self.validSHA256(eventSHA256) else {
            throw HostwrightEventStreamError.invalidCursor
        }
        self.eventID = eventID
        self.eventSHA256 = eventSHA256
    }

    public init(token: String) throws {
        guard token.utf8.count <= Self.maximumTokenBytes,
              token.hasPrefix(Self.prefix) else {
            throw HostwrightEventStreamError.invalidCursor
        }
        let encoded = String(token.dropFirst(Self.prefix.count))
        guard let data = Data(base64URLEncoded: encoded),
              data.base64URLEncodedString() == encoded,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["eventID", "eventSHA256", "schemaVersion"],
              object["schemaVersion"] as? Int == Self.schemaVersion,
              let eventID = object["eventID"] as? String,
              let eventSHA256 = object["eventSHA256"] as? String,
              Self.validEventID(eventID),
              Self.validSHA256(eventSHA256),
              let canonical = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              canonical == data else {
            throw HostwrightEventStreamError.invalidCursor
        }
        self.eventID = eventID
        self.eventSHA256 = eventSHA256
    }

    public var token: String {
        let payload =
            #"{"eventID":"\#(eventID)","eventSHA256":"\#(eventSHA256)","schemaVersion":\#(Self.schemaVersion)}"#
        let data = Data(payload.utf8)
        return Self.prefix + data.base64URLEncodedString()
    }

    private static func validEventID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 &&
            value.range(
                of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$",
                options: .regularExpression
            ) != nil
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    }
}

public struct HostwrightEventStreamFilter: Equatable, Sendable {
    public let projectID: String?
    public let type: String?
    public let serviceName: String?
    public let severity: StateEventSeverity?

    public init(
        projectID: String? = nil,
        type: String? = nil,
        serviceName: String? = nil,
        severity: StateEventSeverity? = nil
    ) {
        self.projectID = projectID
        self.type = type
        self.serviceName = serviceName
        self.severity = severity
    }

    fileprivate func validate() throws {
        try validate(projectID, label: "Event project filter", maximumBytes: 255)
        try validate(type, label: "Event type filter", maximumBytes: 255)
        try validate(serviceName, label: "Event service filter", maximumBytes: 255)
    }

    private func validate(_ value: String?, label: String, maximumBytes: Int) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value.range(of: "^[ -~]+$", options: .regularExpression) != nil else {
            throw HostwrightEventStreamError.invalidFilter(
                "\(label) must be non-empty printable text within \(maximumBytes) bytes."
            )
        }
    }
}

public enum HostwrightEventStreamStatus: String, Equatable, Sendable {
    case ready
    case retentionGap = "retention-gap"
    case timeout
}

public enum HostwrightEventClass: String, CaseIterable, Equatable, Sendable {
    case desiredChange = "desired-change"
    case plan
    case action
    case health
    case policy
    case recovery
    case garbageCollection = "garbage-collection"
    case providerState = "provider-state"
    case operatorDecision = "operator-decision"
    case state

    public static func classify(type: String) -> HostwrightEventClass {
        let normalized = type.lowercased()
        let prefix = normalized.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        if ["configuration.", "desired.", "manifest.", "daemon.configuration."].contains(
            where: normalized.hasPrefix
        ) {
            return .desiredChange
        }
        if prefix == "plan" || normalized.hasSuffix(".planned") {
            return .plan
        }
        if ["state.retention.", "retention.", "gc."].contains(where: normalized.hasPrefix) {
            return .garbageCollection
        }
        if ["state.maintenance.", "image.trust.", "image.vulnerability.", "image.provenance.",
            "image.sbom."].contains(where: normalized.hasPrefix) {
            return .policy
        }
        switch prefix {
        case "apply", "lifecycle", "operation", "cleanup": return .action
        case "health": return .health
        case "policy", "maintenance", "restart", "approval", "trust", "security": return .policy
        case "recovery", "rollback": return .recovery
        case "runtime", "provider", "image", "storage", "network": return .providerState
        case "operator", "team", "secret": return .operatorDecision
        default: return .state
        }
    }
}

public struct HostwrightEventStreamRecord: Equatable, Sendable {
    public let position: UInt64
    public let event: EventRecord
    public let eventClass: HostwrightEventClass
    public let cursor: String
    public let eventReference: String
    public let operationReferences: [String]
    public let auditReference: String?

    fileprivate init(position: UInt64, event: EventRecord) throws {
        let digest = try EventStreamDigest.sha256(event)
        let redacted = event.redacted()
        self.position = position
        self.event = redacted
        eventClass = HostwrightEventClass.classify(type: redacted.type)
        cursor = try HostwrightEventCursor(
            eventID: redacted.id,
            eventSHA256: digest
        ).token
        eventReference = "sha256:\(digest)"
        operationReferences = EventStreamDigest.operationReferences(redacted)
        auditReference = EventAuditClassifier.isAudit(
            type: redacted.type,
            source: redacted.source
        ) ? eventReference : nil
    }
}

public struct HostwrightEventRetentionGap: Equatable, Sendable {
    public let requestedCursor: String
    public let earliestAvailableCursor: String?
    public let latestAvailableCursor: String?

    public init(
        requestedCursor: String,
        earliestAvailableCursor: String?,
        latestAvailableCursor: String?
    ) {
        self.requestedCursor = requestedCursor
        self.earliestAvailableCursor = earliestAvailableCursor
        self.latestAvailableCursor = latestAvailableCursor
    }
}

public struct HostwrightEventStreamPage: Equatable, Sendable {
    public static let schemaVersion = 1
    public static let defaultPageSize = 100
    public static let maximumPageSize = 1_000

    public let status: HostwrightEventStreamStatus
    public let events: [HostwrightEventStreamRecord]
    public let nextCursor: String?
    public let moreAvailable: Bool
    public let retentionGap: HostwrightEventRetentionGap?

    public init(
        status: HostwrightEventStreamStatus,
        events: [HostwrightEventStreamRecord],
        nextCursor: String?,
        moreAvailable: Bool,
        retentionGap: HostwrightEventRetentionGap?
    ) {
        self.status = status
        self.events = events
        self.nextCursor = nextCursor
        self.moreAvailable = moreAvailable
        self.retentionGap = retentionGap
    }

    public func timedOut() -> HostwrightEventStreamPage {
        HostwrightEventStreamPage(
            status: .timeout,
            events: events,
            nextCursor: nextCursor,
            moreAvailable: moreAvailable,
            retentionGap: retentionGap
        )
    }
}

public enum EventAuditClassifier {
    public static func isAudit(type: String, source: String) -> Bool {
        let normalizedType = type.lowercased()
        let text = "\(normalizedType).\(source.lowercased())"
        let exactTypes: Set<String> = [
            "restart.policy.manual-release",
            "team.approval.recorded",
            "team.profile.selected"
        ]
        let protectedPrefixes = [
            "image.provenance.",
            "image.sbom.",
            "image.trust.",
            "image.vulnerability.",
            "secret.",
            "security.",
            "state.maintenance.",
            "state.retention."
        ]
        return exactTypes.contains(normalizedType) ||
            protectedPrefixes.contains { normalizedType.hasPrefix($0) } ||
            ["audit", "security", "maintenance", "retention", "operator"].contains {
                text.contains($0)
            }
    }
}

extension EventLedger {
    public func latestCursor() throws -> String? {
        try store.withValidatedConnection(readOnly: true) { connection in
            guard let row = try connection.query(
                """
                SELECT rowid, id, timestamp, severity, type, source, project_id,
                       service_name, runtime_adapter, message, payload_json_redacted
                FROM event_ledger
                ORDER BY rowid DESC
                LIMIT 1
                """
            ).first else { return nil }
            return try streamRecord(row).cursor
        }
    }

    public func streamPage(
        after cursorToken: String?,
        filter: HostwrightEventStreamFilter = HostwrightEventStreamFilter(),
        pageSize: Int = HostwrightEventStreamPage.defaultPageSize
    ) throws -> HostwrightEventStreamPage {
        try filter.validate()
        guard (1...HostwrightEventStreamPage.maximumPageSize).contains(pageSize) else {
            throw HostwrightEventStreamError.invalidFilter(
                "Event page size must be between 1 and \(HostwrightEventStreamPage.maximumPageSize)."
            )
        }
        let requestedCursor = try cursorToken.map(HostwrightEventCursor.init(token:))

        return try store.withValidatedConnection(readOnly: true) { connection in
            var anchor: UInt64 = 0
            var gap = false
            if let requestedCursor {
                let rows = try connection.query(
                    """
                    SELECT rowid, id, timestamp, severity, type, source, project_id,
                           service_name, runtime_adapter, message, payload_json_redacted
                    FROM event_ledger
                    WHERE id = ?
                    LIMIT 1
                    """,
                    bindings: [.text(requestedCursor.eventID)]
                )
                if let row = rows.first {
                    let record = try streamRecord(row)
                    guard record.eventReference == "sha256:\(requestedCursor.eventSHA256)" else {
                        throw HostwrightEventStreamError.cursorIntegrityMismatch
                    }
                    anchor = record.position
                } else {
                    gap = true
                }
            }

            let boundaryRows = try connection.query(
                """
                SELECT rowid, id, timestamp, severity, type, source, project_id,
                       service_name, runtime_adapter, message, payload_json_redacted
                FROM event_ledger
                ORDER BY rowid DESC
                LIMIT 1
                """
            )
            guard let latestRow = boundaryRows.first else {
                let retentionGap = gap ? cursorToken.map {
                    HostwrightEventRetentionGap(
                        requestedCursor: $0,
                        earliestAvailableCursor: nil,
                        latestAvailableCursor: nil
                    )
                } : nil
                return HostwrightEventStreamPage(
                    status: gap ? .retentionGap : .ready,
                    events: [],
                    nextCursor: nil,
                    moreAvailable: false,
                    retentionGap: retentionGap
                )
            }
            let latest = try streamRecord(latestRow)
            let highWater = latest.position
            let earliestRow = try connection.query(
                """
                SELECT rowid, id, timestamp, severity, type, source, project_id,
                       service_name, runtime_adapter, message, payload_json_redacted
                FROM event_ledger
                ORDER BY rowid ASC
                LIMIT 1
                """
            ).first
            let earliest = try earliestRow.map(streamRecord)

            var clauses = ["rowid > ?", "rowid <= ?"]
            var bindings: [SQLiteValue] = [
                .int64(Int64(anchor)),
                .int64(Int64(highWater))
            ]
            if let projectID = filter.projectID {
                clauses.append(
                    """
                    (project_id = ? OR (
                        project_id IS NULL AND type LIKE 'image.trust.%' AND
                        CASE WHEN json_valid(payload_json_redacted)
                            THEN json_extract(payload_json_redacted, '$.projectID')
                            ELSE NULL
                        END = ?
                    ))
                    """
                )
                bindings.append(.text(projectID))
                bindings.append(.text(projectID))
            }
            if let type = filter.type {
                clauses.append("type = ?")
                bindings.append(.text(type))
            }
            if let serviceName = filter.serviceName {
                clauses.append("service_name = ?")
                bindings.append(.text(serviceName))
            }
            if let severity = filter.severity {
                clauses.append("severity = ?")
                bindings.append(.text(severity.rawValue))
            }
            bindings.append(.int(pageSize + 1))
            let rows = try connection.query(
                """
                SELECT rowid, id, timestamp, severity, type, source, project_id,
                       service_name, runtime_adapter, message, payload_json_redacted
                FROM event_ledger
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY rowid ASC
                LIMIT ?
                """,
                bindings: bindings
            )
            let moreAvailable = rows.count > pageSize
            let records = try rows.prefix(pageSize).map(streamRecord)
            let nextCursor: String?
            if moreAvailable, let last = records.last {
                nextCursor = last.cursor
            } else {
                nextCursor = latest.cursor
            }
            let retentionGap = gap ? cursorToken.map {
                HostwrightEventRetentionGap(
                    requestedCursor: $0,
                    earliestAvailableCursor: earliest?.cursor,
                    latestAvailableCursor: latest.cursor
                )
            } : nil
            return HostwrightEventStreamPage(
                status: gap ? .retentionGap : .ready,
                events: records,
                nextCursor: nextCursor,
                moreAvailable: moreAvailable,
                retentionGap: retentionGap
            )
        }
    }
}

private func streamRecord(_ row: [String?]) throws -> HostwrightEventStreamRecord {
    guard row.count == 11,
          let rawPosition = row[0],
          let position = UInt64(rawPosition),
          position > 0 else {
        throw StateStoreError.invalidRecord("Event stream row has an invalid append position.")
    }
    return try HostwrightEventStreamRecord(
        position: position,
        event: eventRecord(from: Array(row.dropFirst()))
    )
}

private enum EventStreamDigest {
    static func sha256(_ event: EventRecord) throws -> String {
        var object: [String: Any] = [
            "id": event.id,
            "message": event.message,
            "payloadJSONRedacted": event.payloadJSONRedacted,
            "severity": event.severity.rawValue,
            "source": event.source,
            "timestamp": event.timestamp,
            "type": event.type
        ]
        if let projectID = event.projectID { object["projectID"] = projectID }
        if let runtimeAdapter = event.runtimeAdapter { object["runtimeAdapter"] = runtimeAdapter }
        if let serviceName = event.serviceName { object["serviceName"] = serviceName }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func operationReferences(_ event: EventRecord) -> [String] {
        guard event.payloadJSONRedacted.utf8.count <= 65_536,
              let data = event.payloadJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let keys = [
            "operationID", "operationId", "operation_id",
            "operationGroupID", "operationGroupId", "operation_group_id"
        ]
        return Array(Set(keys.compactMap { object[$0] as? String }.filter(validReference)))
            .sorted()
            .prefix(4)
            .map { $0 }
    }

    private static func validReference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        guard value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            return nil
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
