import Dispatch
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

struct EventsCommandRunner {
    private static let pollingIntervalSeconds: TimeInterval = 0.1

    let stateStoreConfiguration: StateStoreConfiguration
    let projectName: String?
    let filters: EventFilters
    let stream: EventStreamCLIOptions
    let output: CLIOutputFormat
    let monotonicNow: () -> UInt64
    let sleep: (TimeInterval) -> Void
    let isCancelled: () -> Bool

    init(
        stateStoreConfiguration: StateStoreConfiguration,
        projectName: String?,
        filters: EventFilters,
        stream: EventStreamCLIOptions = EventStreamCLIOptions(),
        output: CLIOutputFormat,
        monotonicNow: @escaping () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleep: @escaping (TimeInterval) -> Void = { interval in
            Thread.sleep(forTimeInterval: interval)
        },
        isCancelled: @escaping () -> Bool = { false }
    ) {
        self.stateStoreConfiguration = stateStoreConfiguration
        self.projectName = projectName
        self.filters = filters
        self.stream = stream
        self.output = output
        self.monotonicNow = monotonicNow
        self.sleep = sleep
        self.isCancelled = isCancelled
    }

    func run() -> CLIRunResult {
        do {
            let store = SQLiteStateStore(configuration: stateStoreConfiguration)
            if stream.cursor != nil || stream.watch {
                return try runStream(store: store)
            }
            return try runSnapshot(store: store)
        } catch let error as HostwrightEventStreamError {
            return eventFailure(error)
        } catch {
            let exitCode = CLIExitCode.stateUnavailable
            let message = RuntimeRedactionPolicy.default.redact(String(describing: error))
            if output == .json {
                return CLIRunResult(
                    standardError: CLIJSON.error(
                        code: .stateStoreUnavailable,
                        message: message,
                        exitCode: exitCode
                    ),
                    exitCode: exitCode.rawValue
                )
            }
            return CLIRunResult(
                standardError: "\(HostwrightErrorCode.stateStoreUnavailable.rawValue): \(message)\n",
                exitCode: exitCode.rawValue
            )
        }
    }

    private func runSnapshot(store: SQLiteStateStore) throws -> CLIRunResult {
        let stateDatabasePath = stateStoreConfiguration.databasePath
        let projectID = projectName.map { "project-\($0)" }
        var events = try store.events.loadAll()
            .filter { eventMatchesProject($0, projectID: projectID) }
            .filter { event in filters.type == nil || event.type == filters.type }
            .filter { event in filters.serviceName == nil || event.serviceName == filters.serviceName }
            .filter { event in filters.severity == nil || event.severity == filters.severity }
            .map { $0.redacted() }

        if filters.sort == .descending { events.reverse() }
        let pageSize = filters.limit ?? HostwrightEventStreamPage.defaultPageSize
        guard (1...HostwrightEventStreamPage.maximumPageSize).contains(pageSize) else {
            throw HostwrightEventStreamError.invalidFilter(
                "Event page size must be between 1 and \(HostwrightEventStreamPage.maximumPageSize)."
            )
        }
        let moreAvailable = events.count > pageSize
        if moreAvailable { events = Array(events.prefix(pageSize)) }

        if output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.events(
                    stateDatabasePath: stateDatabasePath,
                    projectName: projectName,
                    filters: filters,
                    events: events,
                    snapshotPageSize: pageSize,
                    snapshotMoreAvailable: moreAvailable
                )
            )
        }

        var lines = snapshotHeader(stateDatabasePath: stateDatabasePath, pageSize: pageSize)
        lines.append("More available: \(moreAvailable)")
        lines.append("")
        lines += render(events: events)
        lines.append("")
        return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
    }

    private func runStream(store: SQLiteStateStore) throws -> CLIRunResult {
        let filter = HostwrightEventStreamFilter(
            projectID: projectName.map { "project-\($0)" },
            type: filters.type,
            serviceName: filters.serviceName,
            severity: filters.severity
        )
        let pageSize = filters.limit ?? HostwrightEventStreamPage.defaultPageSize
        var cursor: String?
        if stream.cursor == HostwrightEventCursor.beginning {
            cursor = nil
        } else if let supplied = stream.cursor {
            cursor = try HostwrightEventCursor(token: supplied).token
        } else if stream.watch {
            cursor = try store.events.latestCursor()
        }

        var page = try store.events.streamPage(
            after: cursor,
            filter: filter,
            pageSize: pageSize
        )
        guard stream.watch, page.events.isEmpty, page.status != .retentionGap else {
            return renderStream(page, pageSize: pageSize)
        }

        let started = monotonicNow()
        let timeoutNanoseconds = UInt64(stream.timeoutSeconds) * 1_000_000_000
        let deadline = started.addingReportingOverflow(timeoutNanoseconds).overflow
            ? UInt64.max
            : started + timeoutNanoseconds
        while monotonicNow() < deadline {
            if isCancelled() { throw HostwrightEventStreamError.cancelled }
            sleep(Self.pollingIntervalSeconds)
            if isCancelled() { throw HostwrightEventStreamError.cancelled }
            page = try store.events.streamPage(
                after: page.nextCursor,
                filter: filter,
                pageSize: pageSize
            )
            if !page.events.isEmpty || page.status == .retentionGap {
                return renderStream(page, pageSize: pageSize)
            }
        }
        return renderStream(page.timedOut(), pageSize: pageSize)
    }

    func renderStream(
        _ page: HostwrightEventStreamPage,
        pageSize: Int
    ) -> CLIRunResult {
        if output == .json {
            return CLIRunResult(
                standardOutput: CLIJSON.eventStream(
                    stateDatabasePath: stateStoreConfiguration.databasePath,
                    projectName: projectName,
                    filters: filters,
                    pageSize: pageSize,
                    watch: stream.watch,
                    timeoutSeconds: stream.watch ? stream.timeoutSeconds : nil,
                    page: page
                )
            )
        }

        var lines = [
            "Hostwright event stream",
            "Schema: v\(HostwrightEventStreamPage.schemaVersion)",
            "State DB: \(stateStoreConfiguration.databasePath)",
            "Status: \(page.status.rawValue)",
            "Page size: \(pageSize)",
            "More available: \(page.moreAvailable)"
        ]
        if let projectName { lines.append("Project: \(projectName)") }
        if let gap = page.retentionGap {
            lines.append("Retention gap: requested cursor is no longer retained")
            lines.append("Earliest available cursor: \(gap.earliestAvailableCursor ?? "none")")
            lines.append("Latest available cursor: \(gap.latestAvailableCursor ?? "none")")
        }
        lines.append("")
        if page.events.isEmpty {
            lines.append("- none")
        } else {
            for record in page.events {
                let event = record.event
                lines.append(
                    "- \(record.position) \(event.timestamp) [\(event.severity.rawValue)] " +
                        "\(event.type) \(event.serviceName ?? "project"): " +
                        RuntimeRedactionPolicy.default.redact(event.message)
                )
                lines.append("  Event reference: \(record.eventReference)")
                lines.append("  Cursor: \(record.cursor)")
            }
        }
        lines.append("Next cursor: \(page.nextCursor ?? "none")")
        lines.append("")
        return CLIRunResult(standardOutput: lines.joined(separator: "\n"))
    }

    private func snapshotHeader(stateDatabasePath: String, pageSize: Int) -> [String] {
        var lines = [
            "Hostwright events",
            "State DB: \(stateDatabasePath)",
            "Page size: \(pageSize)"
        ]
        if let projectName { lines.append("Project: \(projectName)") }
        if filters != EventFilters() {
            lines.append("Sort: \(filters.sort.rawValue)")
            if let type = filters.type { lines.append("Type: \(type)") }
            if let serviceName = filters.serviceName { lines.append("Service: \(serviceName)") }
            if let severity = filters.severity { lines.append("Severity: \(severity.rawValue)") }
            if let limit = filters.limit { lines.append("Limit: \(limit)") }
        }
        return lines
    }

    private func render(events: [EventRecord]) -> [String] {
        if events.isEmpty { return ["- none"] }
        return events.map { event in
            "- \(event.timestamp) [\(event.severity.rawValue)] \(event.type) " +
                "\(event.serviceName ?? "project"): " +
                RuntimeRedactionPolicy.default.redact(event.message)
        }
    }

    private func eventMatchesProject(_ event: EventRecord, projectID: String?) -> Bool {
        guard let projectID else { return true }
        if event.projectID == projectID { return true }
        guard event.projectID == nil,
              event.type.hasPrefix("image.trust."),
              event.payloadJSONRedacted.utf8.count <= 65_536,
              let data = event.payloadJSONRedacted.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["projectID"] as? String == projectID
    }

    private func eventFailure(_ error: HostwrightEventStreamError) -> CLIRunResult {
        let exitCode: CLIExitCode
        switch error {
        case .invalidCursor, .invalidFilter:
            exitCode = .validation
        case .cursorIntegrityMismatch:
            exitCode = .stateUnavailable
        case .cancelled:
            exitCode = .partialFailure
        }
        let prefix = "\(error.code): "
        let detail = error.description.hasPrefix(prefix)
            ? String(error.description.dropFirst(prefix.count))
            : error.description
        let message = RuntimeRedactionPolicy.default.redact(detail)
        if output == .json {
            return CLIRunResult(
                standardError: CLIJSON.eventError(
                    code: error.code,
                    message: message,
                    exitCode: exitCode
                ),
                exitCode: exitCode.rawValue
            )
        }
        return CLIRunResult(
            standardError: "\(error.code): \(message)\n",
            exitCode: exitCode.rawValue
        )
    }
}
