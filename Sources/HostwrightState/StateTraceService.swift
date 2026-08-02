import CryptoKit
import Foundation
import HostwrightObservability

public final class StateTraceSink: HostwrightTraceSinking, @unchecked Sendable {
    private let store: SQLiteStateStore

    public init(store: SQLiteStateStore) {
        self.store = store
    }

    public func record(_ span: HostwrightTraceSpanRecord) -> HostwrightTraceEmission {
        do {
            let validated = try span.validated()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(validated)
            guard payload.count <= HostwrightTraceContract.maximumEncodedSpanBytes else {
                throw HostwrightTraceError.spanTooLarge
            }
            try store.events.append([EventRecord(
                id: "trace-span-\(validated.spanID)",
                timestamp: validated.endedAt,
                severity: validated.status == .failed ? .error :
                    (validated.status == .cancelled ? .warning : .info),
                type: HostwrightTraceContract.eventType,
                source: HostwrightTraceContract.source,
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Bounded local trace span completed.",
                payloadJSONRedacted: String(decoding: payload, as: UTF8.self)
            )])
            return HostwrightTraceEmission(status: .persisted)
        } catch {
            emitDegraded()
            return HostwrightTraceEmission(
                status: .degraded,
                reasonCode: HostwrightTraceError.sinkDegraded.code
            )
        }
    }

    private func emitDegraded() {
        guard let correlationID = HostwrightLogContext.correlationID,
              let record = try? HostwrightLogRecord(
                category: .state,
                severity: .error,
                reason: .sinkDegraded,
                correlationID: correlationID,
                outcome: .failed,
                fields: [
                    HostwrightLogField(
                        name: .component,
                        value: "trace",
                        privacy: .publicValue
                    ),
                    HostwrightLogField(
                        name: .status,
                        value: "degraded",
                        privacy: .publicValue
                    )
                ]
              ) else { return }
        HostwrightLogContext.emit(record)
    }
}

public struct StateTraceService: Sendable {
    private struct TraceIdentity: Codable {
        let schemaVersion: Int
        let kind: String
        let traceID: String
        let processCorrelationID: String
        let complete: Bool
        let status: HostwrightTraceSpanStatus?
        let droppedSpanCount: Int
        let spans: [HostwrightTraceSpanRecord]
        let eventIDs: [String]
        let operationIDs: [String]
    }

    private struct StoredSpan {
        let eventID: String
        let span: HostwrightTraceSpanRecord
    }

    private let store: SQLiteStateStore
    private let date: @Sendable () -> Date

    public init(
        store: SQLiteStateStore,
        date: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.date = date
    }

    public func inspect(traceID: String? = nil, limit: Int = 20) throws -> HostwrightTracePage {
        guard (1...100).contains(limit), traceID.map(Self.isCanonicalUUID) ?? true else {
            throw HostwrightTraceError.invalidSpan
        }
        return try store.withValidatedConnection(readOnly: true) { connection in
            let retainedCount = try retainedTraceCount(connection)
            let identifiers = try traceID.map { [$0] } ?? latestTraceIDs(connection, limit: limit)
            let traces = try identifiers.map { try view(traceID: $0, connection: connection) }
            return HostwrightTracePage(
                generatedAt: ISO8601DateFormatter().string(from: date()),
                traces: traces,
                retainedTraceCount: retainedCount
            )
        }
    }

    public func completeTrace(_ traceID: String) throws -> HostwrightTraceView {
        let page = try inspect(traceID: traceID, limit: 1)
        guard let trace = page.traces.first else { throw HostwrightTraceError.traceNotFound }
        guard trace.complete else { throw HostwrightTraceError.incompleteTrace }
        return trace
    }

    private func retainedTraceCount(_ connection: SQLiteConnection) throws -> Int {
        let value = try connection.query(
            """
            SELECT COUNT(DISTINCT json_extract(payload_json_redacted, '$.traceID'))
            FROM event_ledger
            WHERE type = ? AND source = ?
            """,
            bindings: [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source)
            ]
        ).first?.first ?? nil
        guard let value, let count = Int(value), count >= 0 else {
            throw StateStoreError.invalidRecord("Trace count is invalid.")
        }
        return count
    }

    private func latestTraceIDs(_ connection: SQLiteConnection, limit: Int) throws -> [String] {
        let rows = try connection.query(
            """
            SELECT json_extract(payload_json_redacted, '$.traceID'), MAX(rowid)
            FROM event_ledger
            WHERE type = ? AND source = ?
            GROUP BY 1
            ORDER BY 2 DESC
            LIMIT ?
            """,
            bindings: [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source),
                .int(limit)
            ]
        )
        return try rows.map { row in
            guard row.count == 2, let identifier = row[0], Self.isCanonicalUUID(identifier) else {
                throw StateStoreError.invalidRecord("A retained trace identifier is invalid.")
            }
            return identifier
        }
    }

    private func view(traceID: String, connection: SQLiteConnection) throws -> HostwrightTraceView {
        let rows = try connection.query(
            """
            SELECT id, payload_json_redacted
            FROM event_ledger
            WHERE type = ? AND source = ?
              AND json_extract(payload_json_redacted, '$.traceID') = ?
            ORDER BY timestamp ASC, rowid ASC
            LIMIT ?
            """,
            bindings: [
                .text(HostwrightTraceContract.eventType),
                .text(HostwrightTraceContract.source),
                .text(traceID),
                .int(HostwrightTraceContract.maximumSpans + 1)
            ]
        )
        guard !rows.isEmpty else { throw HostwrightTraceError.traceNotFound }
        guard rows.count <= HostwrightTraceContract.maximumSpans else {
            throw HostwrightTraceError.spanLimitExceeded
        }
        let decoder = JSONDecoder()
        let stored = try rows.map { row -> StoredSpan in
            guard row.count == 2, let eventID = row[0], let payload = row[1] else {
                throw StateStoreError.invalidRecord("A trace event row has an invalid shape.")
            }
            let span = try decoder.decode(
                HostwrightTraceSpanRecord.self,
                from: Data(payload.utf8)
            ).validated()
            guard span.traceID == traceID,
                  eventID == "trace-span-\(span.spanID)" else {
                throw StateStoreError.invalidRecord("A trace event identity does not match its span.")
            }
            return StoredSpan(eventID: eventID, span: span)
        }
        guard Set(stored.map { $0.span.spanID }).count == stored.count else {
            throw StateStoreError.invalidRecord("A trace contains duplicate span identifiers.")
        }
        let spanPairs: [(String, HostwrightTraceSpanRecord)] = stored.map {
            ($0.span.spanID, $0.span)
        }
        let spansByID: [String: HostwrightTraceSpanRecord] = Dictionary(
            uniqueKeysWithValues: spanPairs
        )
        for item in stored {
            if let parentID = item.span.parentSpanID, let parent = spansByID[parentID],
               item.span.depth != parent.depth + 1 {
                throw StateStoreError.invalidRecord("A trace span depth does not match its retained parent.")
            }
        }
        let spans = stored.map { $0.span }.sorted {
            ($0.startedAt, $0.depth, $0.spanID) < ($1.startedAt, $1.depth, $1.spanID)
        }
        let roots = spans.filter { $0.parentSpanID == nil }
        let terminalRoots = roots.filter { root in
            root.name == .cliRequest || root.name == .daemonReconciliation
        }
        let terminalRoot: HostwrightTraceSpanRecord? = terminalRoots.last
        let correlations = Set(spans.map { $0.processCorrelationID })
        guard correlations.count == 1, let correlation = correlations.first else {
            throw StateStoreError.invalidRecord("A trace contains conflicting process correlations.")
        }
        let traceEventIDs = stored.map { $0.eventID }
        let spanEventIDs = spans.flatMap { $0.eventIDs }
        let linkedEvents = Set(traceEventIDs).union(spanEventIDs).sorted()
        let linkedOperations = Set(spans.flatMap { $0.operationIDs }).sorted()
        let droppedAttribute = terminalRoot?.attributes.first { attribute in
            attribute.key == .droppedSpans
        }
        let dropped = droppedAttribute.flatMap { Int($0.value) } ?? 0
        let complete = terminalRoot != nil
        let identity = TraceIdentity(
            schemaVersion: HostwrightTraceContract.schemaVersion,
            kind: "hostwright.trace",
            traceID: traceID,
            processCorrelationID: correlation,
            complete: complete,
            status: terminalRoot?.status,
            droppedSpanCount: dropped,
            spans: spans,
            eventIDs: linkedEvents,
            operationIDs: linkedOperations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(identity))
            .map { String(format: "%02x", $0) }.joined()
        return HostwrightTraceView(
            traceID: traceID,
            processCorrelationID: correlation,
            complete: complete,
            status: terminalRoot?.status,
            droppedSpanCount: dropped,
            spans: spans,
            eventIDs: linkedEvents,
            operationIDs: linkedOperations,
            traceSHA256: digest
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}
