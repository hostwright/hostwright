import Foundation

public enum HostwrightTraceSpanName: String, Codable, CaseIterable, Sendable {
    case cliRequest = "cli.request"
    case daemonReconciliation = "daemon.reconciliation"
    case planCompile = "plan.compile"
    case sagaExecute = "saga.execute"
    case sagaRecover = "saga.recover"
    case providerObserve = "provider.observe"
    case providerApply = "provider.apply"
    case healthEvaluate = "health.evaluate"
    case rollbackCompensate = "rollback.compensate"
    case finalizerExecute = "finalizer.execute"
    case cleanupVerify = "cleanup.verify"
    case statePersist = "state.persist"
}

public enum HostwrightTraceSpanStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}

public enum HostwrightTraceAttributeKey: String, Codable, CaseIterable, Sendable {
    case attempt
    case command
    case component
    case daemonIteration = "daemon_iteration"
    case droppedSpans = "dropped_spans"
    case mode
    case nodeCount = "node_count"
    case phase
    case reasonCode = "reason_code"
    case sampling
}

public struct HostwrightTraceAttribute: Codable, Equatable, Sendable {
    public let key: HostwrightTraceAttributeKey
    public let value: String

    public init(key: HostwrightTraceAttributeKey, value: String) throws {
        guard Self.isValid(value, for: key) else {
            throw HostwrightTraceError.invalidAttribute(key.rawValue)
        }
        self.key = key
        self.value = value
    }

    private static func isValid(_ value: String, for key: HostwrightTraceAttributeKey) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        switch key {
        case .attempt:
            return boundedInteger(value, range: 1...3)
        case .command:
            return [
                "apply", "cleanup", "daemon", "down", "recovery", "restart", "rm",
                "up", "update"
            ].contains(value)
        case .component:
            return [
                "cleanup", "cli", "daemon", "health", "reconciler", "recovery",
                "runtime", "state"
            ].contains(value)
        case .daemonIteration:
            return boundedInteger(value, range: 1...1_000_000_000)
        case .droppedSpans:
            return boundedInteger(value, range: 0...HostwrightTraceContract.maximumSpans)
        case .mode:
            return ["foreground-dev", "managed-service"].contains(value)
        case .nodeCount:
            return boundedInteger(value, range: 0...10_000)
        case .phase:
            return [
                "apply", "compensate", "execute", "finalize", "observe", "prepare",
                "recover", "verify"
            ].contains(value)
        case .reasonCode:
            return value.range(of: "^[A-Z][A-Z0-9-]{2,31}$", options: .regularExpression) != nil
        case .sampling:
            return ["all", "deterministic-1-of-16", "failure-override"].contains(value)
        }
    }

    private static func boundedInteger(_ value: String, range: ClosedRange<Int>) -> Bool {
        guard value.range(of: "^[0-9]{1,10}$", options: .regularExpression) != nil,
              let number = Int(value) else { return false }
        return range.contains(number)
    }
}

public enum HostwrightTraceContract {
    public static let schemaVersion = 1
    public static let eventType = "trace.span.v1"
    public static let source = "hostwright.trace"
    public static let maximumSpans = 64
    public static let maximumDepth = 12
    public static let maximumAttributes = 8
    public static let maximumEventLinks = 16
    public static let maximumOperationLinks = 16
    public static let maximumEncodedSpanBytes = 8 * 1_024
    public static let maximumExportBytes = 1 * 1_024 * 1_024
    public static let deterministicSampleDenominator: UInt64 = 16

    static func isSafeLinkIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 128,
              HostwrightLogSanitizer.isIdentifier(value),
              SecretRedactor.redact(value: value, secretKeys: []) == value else {
            return false
        }
        return value.range(
            of: "(?i)(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{16,})",
            options: .regularExpression
        ) == nil
    }
}

public struct HostwrightTraceSpanRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let traceID: String
    public let spanID: String
    public let parentSpanID: String?
    public let processCorrelationID: String
    public let name: HostwrightTraceSpanName
    public let status: HostwrightTraceSpanStatus
    public let startedAt: String
    public let endedAt: String
    public let durationMilliseconds: UInt64
    public let depth: Int
    public let attributes: [HostwrightTraceAttribute]
    public let eventIDs: [String]
    public let operationIDs: [String]

    public init(
        traceID: String,
        spanID: String,
        parentSpanID: String?,
        processCorrelationID: String,
        name: HostwrightTraceSpanName,
        status: HostwrightTraceSpanStatus,
        startedAt: String,
        endedAt: String,
        durationMilliseconds: UInt64,
        depth: Int,
        attributes: [HostwrightTraceAttribute] = [],
        eventIDs: [String] = [],
        operationIDs: [String] = []
    ) throws {
        guard Self.isCanonicalUUID(traceID), Self.isCanonicalUUID(spanID),
              parentSpanID.map(Self.isCanonicalUUID) ?? true,
              Self.isCanonicalUUID(processCorrelationID),
              parentSpanID != spanID,
              depth >= 0, depth <= HostwrightTraceContract.maximumDepth,
              (parentSpanID == nil) == (depth == 0),
              durationMilliseconds <= 86_400_000,
              Self.timestamp(startedAt) != nil, Self.timestamp(endedAt) != nil,
              attributes.count <= HostwrightTraceContract.maximumAttributes,
              Set(attributes.map(\.key)).count == attributes.count,
              eventIDs.count <= HostwrightTraceContract.maximumEventLinks,
              operationIDs.count <= HostwrightTraceContract.maximumOperationLinks,
              Set(eventIDs).count == eventIDs.count,
              Set(operationIDs).count == operationIDs.count,
              eventIDs.allSatisfy(Self.isBoundedIdentifier),
              operationIDs.allSatisfy(Self.isBoundedIdentifier) else {
            throw HostwrightTraceError.invalidSpan
        }
        guard let start = Self.timestamp(startedAt), let end = Self.timestamp(endedAt),
              end >= start else {
            throw HostwrightTraceError.invalidSpan
        }
        self.schemaVersion = HostwrightTraceContract.schemaVersion
        self.kind = "hostwright.trace.span"
        self.traceID = traceID
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.processCorrelationID = processCorrelationID
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.depth = depth
        self.attributes = attributes.sorted { $0.key.rawValue < $1.key.rawValue }
        self.eventIDs = eventIDs.sorted()
        self.operationIDs = operationIDs.sorted()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encoded = try? encoder.encode(self),
              encoded.count <= HostwrightTraceContract.maximumEncodedSpanBytes else {
            throw HostwrightTraceError.spanTooLarge
        }
    }

    public func validated() throws -> HostwrightTraceSpanRecord {
        guard schemaVersion == HostwrightTraceContract.schemaVersion,
              kind == "hostwright.trace.span" else {
            throw HostwrightTraceError.unsupportedSchema
        }
        return try HostwrightTraceSpanRecord(
            traceID: traceID,
            spanID: spanID,
            parentSpanID: parentSpanID,
            processCorrelationID: processCorrelationID,
            name: name,
            status: status,
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: durationMilliseconds,
            depth: depth,
            attributes: attributes,
            eventIDs: eventIDs,
            operationIDs: operationIDs
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        HostwrightTraceContract.isSafeLinkIdentifier(value)
    }

    private static func timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

public enum HostwrightTraceEmissionStatus: String, Codable, Sendable {
    case persisted
    case buffered
    case unsampled
    case degraded
}

public struct HostwrightTraceView: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let traceID: String
    public let processCorrelationID: String
    public let complete: Bool
    public let status: HostwrightTraceSpanStatus?
    public let spanCount: Int
    public let droppedSpanCount: Int
    public let spans: [HostwrightTraceSpanRecord]
    public let eventIDs: [String]
    public let operationIDs: [String]
    public let traceSHA256: String

    public init(
        traceID: String,
        processCorrelationID: String,
        complete: Bool,
        status: HostwrightTraceSpanStatus?,
        droppedSpanCount: Int,
        spans: [HostwrightTraceSpanRecord],
        eventIDs: [String],
        operationIDs: [String],
        traceSHA256: String
    ) {
        self.schemaVersion = HostwrightTraceContract.schemaVersion
        self.kind = "hostwright.trace"
        self.traceID = traceID
        self.processCorrelationID = processCorrelationID
        self.complete = complete
        self.status = status
        self.spanCount = spans.count
        self.droppedSpanCount = droppedSpanCount
        self.spans = spans
        self.eventIDs = eventIDs
        self.operationIDs = operationIDs
        self.traceSHA256 = traceSHA256
    }
}

public struct HostwrightTracePage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let traces: [HostwrightTraceView]
    public let retainedTraceCount: Int
    public let retentionAuthority: String
    public let automaticUpload: Bool

    public init(generatedAt: String, traces: [HostwrightTraceView], retainedTraceCount: Int) {
        self.schemaVersion = HostwrightTraceContract.schemaVersion
        self.kind = "hostwright.trace.page"
        self.generatedAt = generatedAt
        self.traces = traces
        self.retainedTraceCount = retainedTraceCount
        self.retentionAuthority = "state-retention-v1:traces"
        self.automaticUpload = false
    }
}

public struct HostwrightTraceExportReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let traceID: String
    public let traceSHA256: String
    public let outputPath: String
    public let outputSHA256: String
    public let outputBytes: UInt64
    public let automaticUpload: Bool
    public let ownership: String

    public init(
        traceID: String,
        traceSHA256: String,
        outputPath: String,
        outputSHA256: String,
        outputBytes: UInt64
    ) {
        self.schemaVersion = HostwrightTraceContract.schemaVersion
        self.kind = "hostwright.trace.export"
        self.traceID = traceID
        self.traceSHA256 = traceSHA256
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputBytes = outputBytes
        self.automaticUpload = false
        self.ownership = "operator-owned"
    }
}

public struct HostwrightTraceEmission: Equatable, Sendable {
    public let status: HostwrightTraceEmissionStatus
    public let reasonCode: String?

    public init(status: HostwrightTraceEmissionStatus, reasonCode: String? = nil) {
        self.status = status
        self.reasonCode = reasonCode
    }
}

public protocol HostwrightTraceSinking: Sendable {
    func record(_ span: HostwrightTraceSpanRecord) -> HostwrightTraceEmission
}

public enum HostwrightTraceError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidAttribute(String)
    case invalidSpan
    case spanLimitExceeded
    case depthLimitExceeded
    case spanTooLarge
    case unsupportedSchema
    case traceNotFound
    case incompleteTrace
    case confirmationMismatch
    case unsafeExportPath
    case sinkDegraded

    public var code: String {
        switch self {
        case .invalidAttribute, .invalidSpan: "HW-TRACE-001"
        case .spanLimitExceeded, .depthLimitExceeded, .spanTooLarge: "HW-TRACE-002"
        case .unsupportedSchema: "HW-TRACE-003"
        case .traceNotFound: "HW-TRACE-004"
        case .incompleteTrace: "HW-TRACE-005"
        case .confirmationMismatch: "HW-TRACE-006"
        case .unsafeExportPath: "HW-TRACE-007"
        case .sinkDegraded: "HW-TRACE-008"
        }
    }

    public var description: String {
        switch self {
        case .invalidAttribute(let key): "\(code): Trace attribute '\(key)' is invalid."
        case .invalidSpan: "\(code): Trace span identity, timing, links, or shape is invalid."
        case .spanLimitExceeded: "\(code): The trace exceeds its fixed span limit."
        case .depthLimitExceeded: "\(code): The trace exceeds its fixed nesting depth."
        case .spanTooLarge: "\(code): The trace span exceeds its fixed encoded size."
        case .unsupportedSchema: "\(code): The trace record schema is unsupported."
        case .traceNotFound: "\(code): The requested retained trace does not exist."
        case .incompleteTrace: "\(code): The requested trace has no terminal root span."
        case .confirmationMismatch: "\(code): The retained trace changed; inspect it again before export."
        case .unsafeExportPath: "\(code): Trace export requires one normalized absolute new private file path."
        case .sinkDegraded: "\(code): Trace persistence degraded; the owning control result is unchanged."
        }
    }
}

public struct HostwrightTraceSpanToken: Sendable {
    fileprivate let spanID: String
    fileprivate let parentSpanID: String?
    fileprivate let depth: Int
    fileprivate let name: HostwrightTraceSpanName
    fileprivate let startedAt: String
    fileprivate let startedNanoseconds: UInt64
    fileprivate let attributes: [HostwrightTraceAttribute]
}

public final class HostwrightTraceSession: @unchecked Sendable {
    private let lock = NSLock()
    private let date: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private let identifier: @Sendable () -> String
    private var sink: (any HostwrightTraceSinking)?
    private var buffered: [HostwrightTraceSpanRecord] = []
    private var eventIDs = Set<String>()
    private var operationIDs = Set<String>()
    private var createdSpans = 0
    private var droppedSpans = 0
    private var selected: Bool
    private var completed = false

    public let traceID: String
    public let processCorrelationID: String

    public init(
        traceID: String,
        processCorrelationID: String,
        selected: Bool,
        date: @escaping @Sendable () -> Date = Date.init,
        monotonicNow: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        identifier: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
    ) throws {
        guard let traceUUID = UUID(uuidString: traceID),
              traceUUID.uuidString.lowercased() == traceID,
              let correlationUUID = UUID(uuidString: processCorrelationID),
              correlationUUID.uuidString.lowercased() == processCorrelationID else {
            throw HostwrightTraceError.invalidSpan
        }
        self.traceID = traceID
        self.processCorrelationID = processCorrelationID
        self.selected = selected
        self.date = date
        self.monotonicNow = monotonicNow
        self.identifier = identifier
    }

    public static func deterministicSelection(traceID: String) -> Bool {
        guard let uuid = UUID(uuidString: traceID) else { return false }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let value = bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return value % HostwrightTraceContract.deterministicSampleDenominator == 0
    }

    public func attach(_ sink: any HostwrightTraceSinking) {
        let pending: [HostwrightTraceSpanRecord]
        lock.lock()
        guard self.sink == nil, !completed else {
            lock.unlock()
            return
        }
        self.sink = sink
        if selected {
            pending = buffered
            buffered.removeAll(keepingCapacity: true)
        } else {
            pending = []
        }
        lock.unlock()
        emit(pending, to: sink)
    }

    public func start(
        _ name: HostwrightTraceSpanName,
        attributes: [HostwrightTraceAttribute] = []
    ) -> HostwrightTraceSpanToken? {
        let parent = HostwrightTraceContext.span
        let depth = (parent?.depth ?? -1) + 1
        lock.lock()
        defer { lock.unlock() }
        guard !completed, createdSpans < HostwrightTraceContract.maximumSpans else {
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + 1)
            return nil
        }
        guard depth <= HostwrightTraceContract.maximumDepth,
              attributes.count <= HostwrightTraceContract.maximumAttributes else {
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + 1)
            return nil
        }
        let spanID = identifier().lowercased()
        guard let uuid = UUID(uuidString: spanID), uuid.uuidString.lowercased() == spanID else {
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + 1)
            return nil
        }
        createdSpans += 1
        return HostwrightTraceSpanToken(
            spanID: spanID,
            parentSpanID: parent?.spanID,
            depth: depth,
            name: name,
            startedAt: ISO8601DateFormatter().string(from: date()),
            startedNanoseconds: monotonicNow(),
            attributes: attributes
        )
    }

    @discardableResult
    public func finish(
        _ token: HostwrightTraceSpanToken?,
        status: HostwrightTraceSpanStatus,
        attributes additionalAttributes: [HostwrightTraceAttribute] = []
    ) -> HostwrightTraceEmission {
        guard let token else { return HostwrightTraceEmission(status: .degraded, reasonCode: "HW-TRACE-002") }
        let end = date()
        let endedNanoseconds = monotonicNow()
        let elapsed = endedNanoseconds >= token.startedNanoseconds
            ? (endedNanoseconds - token.startedNanoseconds) / 1_000_000
            : 0
        let snapshot: (any HostwrightTraceSinking, HostwrightTraceSpanRecord)?
        lock.lock()
        do {
            var attributes = token.attributes
            for attribute in additionalAttributes where !attributes.contains(where: { $0.key == attribute.key }) {
                attributes.append(attribute)
            }
            let record = try HostwrightTraceSpanRecord(
                traceID: traceID,
                spanID: token.spanID,
                parentSpanID: token.parentSpanID,
                processCorrelationID: processCorrelationID,
                name: token.name,
                status: status,
                startedAt: token.startedAt,
                endedAt: ISO8601DateFormatter().string(from: end),
                durationMilliseconds: min(elapsed, 86_400_000),
                depth: token.depth,
                attributes: attributes,
                eventIDs: Array(eventIDs.sorted().prefix(HostwrightTraceContract.maximumEventLinks)),
                operationIDs: Array(operationIDs.sorted().prefix(HostwrightTraceContract.maximumOperationLinks))
            )
            if selected, let sink {
                snapshot = (sink, record)
            } else {
                buffered.append(record)
                snapshot = nil
            }
        } catch {
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + 1)
            snapshot = nil
        }
        lock.unlock()
        guard let snapshot else { return HostwrightTraceEmission(status: .buffered) }
        let emission = snapshot.0.record(snapshot.1)
        if emission.status == .degraded {
            lock.lock()
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + 1)
            lock.unlock()
        }
        return emission
    }

    public func linkEvent(_ identifier: String) {
        guard isValidLink(identifier) else { return }
        lock.lock()
        if eventIDs.count < HostwrightTraceContract.maximumEventLinks {
            eventIDs.insert(identifier)
        }
        lock.unlock()
    }

    public func linkOperation(_ identifier: String) {
        guard isValidLink(identifier) else { return }
        lock.lock()
        if operationIDs.count < HostwrightTraceContract.maximumOperationLinks {
            operationIDs.insert(identifier)
        }
        lock.unlock()
    }

    public func rootCompletionAttributes(
        sampling: String
    ) -> [HostwrightTraceAttribute] {
        lock.lock()
        let dropped = min(
            HostwrightTraceContract.maximumSpans,
            droppedSpans + (selected || sampling == "failure-override" ? 0 : buffered.count)
        )
        lock.unlock()
        return [
            try? HostwrightTraceAttribute(key: .sampling, value: sampling),
            try? HostwrightTraceAttribute(key: .droppedSpans, value: String(dropped))
        ].compactMap { $0 }
    }

    public func complete(status: HostwrightTraceSpanStatus) {
        let pending: [HostwrightTraceSpanRecord]
        let destination: (any HostwrightTraceSinking)?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        if status != .succeeded { selected = true }
        if selected {
            pending = buffered
        } else {
            pending = buffered.filter { $0.parentSpanID == nil }
        }
        buffered.removeAll()
        destination = sink
        completed = true
        lock.unlock()
        if let destination { emit(pending, to: destination) }
    }

    private func isValidLink(_ identifier: String) -> Bool {
        HostwrightTraceContract.isSafeLinkIdentifier(identifier)
    }

    private func emit(_ records: [HostwrightTraceSpanRecord], to sink: any HostwrightTraceSinking) {
        var degraded = 0
        for record in records {
            if sink.record(record).status == .degraded { degraded += 1 }
        }
        if degraded > 0 {
            lock.lock()
            droppedSpans = min(HostwrightTraceContract.maximumSpans, droppedSpans + degraded)
            lock.unlock()
        }
    }
}

public enum HostwrightTraceContext {
    public struct Span: Sendable {
        public let spanID: String
        public let depth: Int
    }

    @TaskLocal public static var session: HostwrightTraceSession?
    @TaskLocal public static var span: Span?

    public static func withSession<Result>(
        _ session: HostwrightTraceSession,
        operation: () throws -> Result
    ) rethrows -> Result {
        try $session.withValue(session, operation: operation)
    }

    public static func withSession<Result>(
        _ session: HostwrightTraceSession,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $session.withValue(session, operation: operation)
    }

    public static func withSpan<Result>(
        _ token: HostwrightTraceSpanToken?,
        operation: () throws -> Result
    ) rethrows -> Result {
        guard let token else { return try operation() }
        return try $span.withValue(Span(spanID: token.spanID, depth: token.depth), operation: operation)
    }

    public static func withSpan<Result>(
        _ name: HostwrightTraceSpanName,
        attributes: [HostwrightTraceAttribute] = [],
        operation: () throws -> Result
    ) rethrows -> Result {
        guard let session else { return try operation() }
        let token = session.start(name, attributes: attributes)
        do {
            let result = try withSpan(token, operation: operation)
            _ = session.finish(token, status: .succeeded)
            return result
        } catch {
            _ = session.finish(
                token,
                status: error is CancellationError ? .cancelled : .failed
            )
            throw error
        }
    }

    public static func withSpan<Result>(
        _ token: HostwrightTraceSpanToken?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let token else { return try await operation() }
        return try await $span.withValue(
            Span(spanID: token.spanID, depth: token.depth),
            operation: operation
        )
    }

    public static func withSpan<Result>(
        _ name: HostwrightTraceSpanName,
        attributes: [HostwrightTraceAttribute] = [],
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        guard let session else { return try await operation() }
        let token = session.start(name, attributes: attributes)
        do {
            let result = try await withSpan(token, operation: operation)
            _ = session.finish(token, status: .succeeded)
            return result
        } catch {
            _ = session.finish(
                token,
                status: error is CancellationError ? .cancelled : .failed
            )
            throw error
        }
    }

    public static func withValues<Result>(
        session: HostwrightTraceSession?,
        span: Span?,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $session.withValue(session) {
            try await $span.withValue(span, operation: operation)
        }
    }
}
