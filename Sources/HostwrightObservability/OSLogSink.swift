import Foundation
import OSLog

public final class HostwrightOSLogSink: HostwrightLogSinking, @unchecked Sendable {
    private let configuration: HostwrightLogConfiguration
    private let loggers: [HostwrightLogCategory: Logger]
    private let signposter = OSSignposter(
        subsystem: HostwrightLogRecord.subsystem,
        category: HostwrightLogCategory.lifecycle.rawValue
    )
    private let lock = NSLock()
    private var intervals: [String: OSSignpostIntervalState] = [:]

    public init(configuration: HostwrightLogConfiguration = .live) {
        self.configuration = configuration
        loggers = Dictionary(uniqueKeysWithValues: HostwrightLogCategory.allCases.map { category in
            (
                category,
                Logger(subsystem: HostwrightLogRecord.subsystem, category: category.rawValue)
            )
        })
    }

    public func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        guard configuration.enabled else {
            return HostwrightLogEmission(status: .disabled)
        }
        guard record.severity >= configuration.minimumSeverity else {
            return HostwrightLogEmission(status: .filtered)
        }
        guard let logger = loggers[record.category] else {
            return HostwrightLogEmission(status: .degraded, reasonCode: HostwrightLogReason.sinkDegraded.rawValue)
        }
        let type = logType(record.severity)
        guard logger.isEnabled(type: type) else {
            return HostwrightLogEmission(status: .filtered)
        }

        let message = record.canonicalMessage
        switch record.severity {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .critical:
            logger.critical("\(message, privacy: .public)")
        }
        updateSignpost(record)
        return HostwrightLogEmission(status: .emitted)
    }

    private func logType(_ severity: HostwrightLogSeverity) -> OSLogType {
        switch severity {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .default
        case .error: .error
        case .critical: .fault
        }
    }

    private func updateSignpost(_ record: HostwrightLogRecord) {
        switch record.reason {
        case .cliStarted:
            beginInterval(isCLI: true, correlationID: record.correlationID)
        case .daemonStarted:
            beginInterval(isCLI: false, correlationID: record.correlationID)
        case .cliSucceeded, .cliFailed:
            endInterval(isCLI: true, record: record)
        case .daemonStopped, .daemonFailed:
            endInterval(isCLI: false, record: record)
        case .durableEventInfo, .durableEventWarning, .durableEventError, .sinkDegraded:
            break
        }
    }

    private func beginInterval(isCLI: Bool, correlationID: String) {
        lock.lock()
        guard intervals[correlationID] == nil,
              intervals.count < HostwrightLogRecord.maximumActiveSignposts else {
            lock.unlock()
            return
        }
        let state: OSSignpostIntervalState
        if isCLI {
            state = signposter.beginInterval(
                "CLICommand",
                id: signposter.makeSignpostID(),
                "correlation=\(correlationID, privacy: .public)"
            )
        } else {
            state = signposter.beginInterval(
                "DaemonRun",
                id: signposter.makeSignpostID(),
                "correlation=\(correlationID, privacy: .public)"
            )
        }
        intervals[correlationID] = state
        lock.unlock()
    }

    private func endInterval(isCLI: Bool, record: HostwrightLogRecord) {
        lock.lock()
        let state = intervals.removeValue(forKey: record.correlationID)
        lock.unlock()
        guard let state else { return }
        let outcome = record.outcome.rawValue
        if isCLI {
            signposter.endInterval("CLICommand", state, "outcome=\(outcome, privacy: .public)")
        } else {
            signposter.endInterval("DaemonRun", state, "outcome=\(outcome, privacy: .public)")
        }
    }
}

public enum HostwrightLogContext {
    @TaskLocal public static var sink: (any HostwrightLogSinking)?
    @TaskLocal public static var correlationID: String?

    public static func withValues<Result>(
        sink: any HostwrightLogSinking,
        correlationID: String,
        operation: () throws -> Result
    ) rethrows -> Result {
        try $sink.withValue(sink) {
            try $correlationID.withValue(correlationID, operation: operation)
        }
    }

    public static func withValues<Result>(
        sink: any HostwrightLogSinking,
        correlationID: String,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> Result
    ) async rethrows -> Result {
        try await $sink.withValue(sink) {
            try await $correlationID.withValue(correlationID, operation: operation)
        }
    }

    @discardableResult
    public static func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        sink?.emit(record) ?? HostwrightLogEmission(status: .disabled)
    }
}
