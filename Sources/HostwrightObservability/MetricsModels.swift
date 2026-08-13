import Foundation

public enum HostwrightMetricType: String, Codable, Equatable, Sendable {
    case counter
    case gauge
    case histogram
    case summary
}

public struct HostwrightMetricDescriptor: Equatable, Sendable {
    public let name: String
    public let type: HostwrightMetricType
    public let labels: [String: [String]]

    public init(name: String, type: HostwrightMetricType, labels: [String: [String]] = [:]) {
        self.name = name
        self.type = type
        self.labels = labels
    }
}

public struct HostwrightMetricHistogram: Codable, Equatable, Sendable {
    public let boundaries: [Double]
    public let cumulativeCounts: [UInt64]
    public let count: UInt64
    public let sum: Double

    public init(boundaries: [Double], cumulativeCounts: [UInt64], count: UInt64, sum: Double) {
        self.boundaries = boundaries
        self.cumulativeCounts = cumulativeCounts
        self.count = count
        self.sum = sum
    }
}

public struct HostwrightMetricSummary: Codable, Equatable, Sendable {
    public let count: UInt64
    public let sum: Double
    public let minimum: Double?
    public let maximum: Double?
    public let mean: Double?

    public init(
        count: UInt64,
        sum: Double,
        minimum: Double?,
        maximum: Double?,
        mean: Double?
    ) {
        self.count = count
        self.sum = sum
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
    }
}

public struct HostwrightMetricSeries: Codable, Equatable, Sendable {
    public let name: String
    public let type: HostwrightMetricType
    public let labels: [String: String]
    public let value: UInt64?
    public let histogram: HostwrightMetricHistogram?
    public let summary: HostwrightMetricSummary?

    public init(
        name: String,
        type: HostwrightMetricType,
        labels: [String: String] = [:],
        value: UInt64? = nil,
        histogram: HostwrightMetricHistogram? = nil,
        summary: HostwrightMetricSummary? = nil
    ) {
        self.name = name
        self.type = type
        self.labels = labels
        self.value = value
        self.histogram = histogram
        self.summary = summary
    }
}

public enum HostwrightSLOStatus: String, Codable, Equatable, Sendable {
    case met
    case notMet = "not-met"
    case insufficientData = "insufficient-data"
}

public struct HostwrightSLOResult: Codable, Equatable, Sendable {
    public let name: String
    public let status: HostwrightSLOStatus
    public let comparison: String
    public let target: Double
    public let observed: Double?
    public let sampleCount: UInt64
    public let numerator: UInt64?
    public let denominator: UInt64?
    public let unit: String

    public init(
        name: String,
        status: HostwrightSLOStatus,
        comparison: String,
        target: Double,
        observed: Double?,
        sampleCount: UInt64,
        numerator: UInt64? = nil,
        denominator: UInt64? = nil,
        unit: String
    ) {
        self.name = name
        self.status = status
        self.comparison = comparison
        self.target = target
        self.observed = observed
        self.sampleCount = sampleCount
        self.numerator = numerator
        self.denominator = denominator
        self.unit = unit
    }
}

public struct HostwrightMetricsSource: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let databaseSHA256: String
    public let databaseBytes: UInt64

    public init(schemaVersion: Int, databaseSHA256: String, databaseBytes: UInt64) {
        self.schemaVersion = schemaVersion
        self.databaseSHA256 = databaseSHA256
        self.databaseBytes = databaseBytes
    }
}

public struct HostwrightMetricsRetention: Codable, Equatable, Sendable {
    public let authority: String
    public let separateSampleStore: Bool
    public let automaticUpload: Bool
    public let exportOwnership: String

    public init(
        authority: String = "state-retention-v1",
        separateSampleStore: Bool = false,
        automaticUpload: Bool = false,
        exportOwnership: String = "operator-owned"
    ) {
        self.authority = authority
        self.separateSampleStore = separateSampleStore
        self.automaticUpload = automaticUpload
        self.exportOwnership = exportOwnership
    }
}

public struct HostwrightMetricsSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let generatedAt: String
    public let source: HostwrightMetricsSource
    public let series: [HostwrightMetricSeries]
    public let slos: [HostwrightSLOResult]
    public let retention: HostwrightMetricsRetention
    public let snapshotSHA256: String

    public init(
        schemaVersion: Int = HostwrightMetricCatalog.schemaVersion,
        kind: String = "hostwright.metrics.snapshot",
        generatedAt: String,
        source: HostwrightMetricsSource,
        series: [HostwrightMetricSeries],
        slos: [HostwrightSLOResult],
        retention: HostwrightMetricsRetention = HostwrightMetricsRetention(),
        snapshotSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.generatedAt = generatedAt
        self.source = source
        self.series = series
        self.slos = slos
        self.retention = retention
        self.snapshotSHA256 = snapshotSHA256
    }
}

public struct HostwrightMetricsExportReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let snapshotSHA256: String
    public let outputPath: String
    public let outputSHA256: String
    public let outputBytes: UInt64
    public let automaticUpload: Bool
    public let ownership: String

    public init(
        snapshotSHA256: String,
        outputPath: String,
        outputSHA256: String,
        outputBytes: UInt64
    ) {
        self.schemaVersion = HostwrightMetricCatalog.schemaVersion
        self.kind = "hostwright.metrics.export"
        self.snapshotSHA256 = snapshotSHA256
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.outputBytes = outputBytes
        self.automaticUpload = false
        self.ownership = "operator-owned"
    }
}

public enum HostwrightMetricsError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidSeries(String)
    case seriesBudgetExceeded
    case snapshotChanged
    case unsafeExportPath

    public var code: String {
        switch self {
        case .invalidSeries: "HW-METRIC-001"
        case .seriesBudgetExceeded: "HW-METRIC-002"
        case .snapshotChanged: "HW-METRIC-003"
        case .unsafeExportPath: "HW-METRIC-004"
        }
    }

    public var description: String {
        switch self {
        case .invalidSeries(let detail): "\(code): Invalid metric series: \(detail)"
        case .seriesBudgetExceeded: "\(code): The fixed metric series budget was exceeded."
        case .snapshotChanged: "\(code): The metrics snapshot changed; inspect a fresh snapshot before export."
        case .unsafeExportPath: "\(code): Metrics export requires one normalized absolute new private file path."
        }
    }
}

public enum HostwrightMetricCatalog {
    public static let schemaVersion = 1
    public static let maximumSeries = 128
    public static let maximumLabelValueBytes = 64
    public static let histogramBoundaries = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30]

    public static let descriptors: [HostwrightMetricDescriptor] = [
        descriptor("hostwright_api_requests_total", .counter, "outcome", outcomes),
        descriptor("hostwright_reconciliation_iterations_total", .counter, "outcome", ["failed", "succeeded"]),
        descriptor("hostwright_scheduling_decisions_total", .counter, "decision", schedulingDecisions),
        descriptor("hostwright_runtime_actions_total", .counter, "outcome", outcomes),
        descriptor("hostwright_health_checks_total", .counter, "status", healthStatuses),
        descriptor("hostwright_retries_total", .counter, "decision", retryDecisions),
        descriptor("hostwright_gc_decisions_total", .counter, "outcome", ["failed", "planned", "succeeded"]),
        descriptor("hostwright_errors_total", .counter, "component", components),
        descriptor("hostwright_metrics_dropped_samples_total", .counter, "reason", droppedReasons),
        descriptor("hostwright_storage_resources", .gauge, "resource", ["backup", "snapshot", "volume"]),
        descriptor("hostwright_network_resources", .gauge, "resource", ["attachment", "network", "port-reservation"]),
        descriptor("hostwright_managed_resources", .gauge, "resource", ["health-result", "operation-group", "ownership"]),
        HostwrightMetricDescriptor(name: "hostwright_state_database_bytes", type: .gauge),
        HostwrightMetricDescriptor(name: "hostwright_operation_duration_seconds", type: .histogram),
        HostwrightMetricDescriptor(name: "hostwright_reconciliation_duration_seconds", type: .summary)
    ].sorted { $0.name < $1.name }

    public static let outcomes = ["active", "failed", "interrupted", "succeeded"]
    public static let schedulingDecisions = [
        "admitted", "cancelled", "deferred", "denied", "failed", "hold", "manual-release",
        "override-authorized", "stable-reset", "superseded"
    ]
    public static let healthStatuses = ["healthy", "notConfigured", "skipped", "unhealthy", "unknown"]
    public static let retryDecisions = ["admitted", "denied", "failed", "hold", "manual-release", "stable-reset"]
    public static let components = [
        "api", "gc", "health", "network", "reconciliation", "runtime", "scheduling", "state", "storage"
    ]
    public static let droppedReasons = ["invalid-record", "overflow", "series-budget", "unsupported-duration"]

    public static func validate(_ series: [HostwrightMetricSeries]) throws {
        guard series.count <= maximumSeries else {
            throw HostwrightMetricsError.seriesBudgetExceeded
        }
        let descriptorsByName = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })
        var identities = Set<String>()
        for item in series {
            guard let descriptor = descriptorsByName[item.name], descriptor.type == item.type else {
                throw HostwrightMetricsError.invalidSeries(item.name)
            }
            guard Set(item.labels.keys) == Set(descriptor.labels.keys) else {
                throw HostwrightMetricsError.invalidSeries("\(item.name) labels")
            }
            for (key, value) in item.labels {
                guard value.utf8.count <= maximumLabelValueBytes,
                      descriptor.labels[key]?.contains(value) == true else {
                    throw HostwrightMetricsError.invalidSeries("\(item.name) label \(key)")
                }
            }
            let identity = item.name + "|" + item.labels.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            guard identities.insert(identity).inserted else {
                throw HostwrightMetricsError.invalidSeries("duplicate \(identity)")
            }
            switch item.type {
            case .counter, .gauge:
                guard item.value != nil, item.histogram == nil, item.summary == nil else {
                    throw HostwrightMetricsError.invalidSeries("\(item.name) value shape")
                }
            case .histogram:
                guard item.value == nil, item.summary == nil,
                      let histogram = item.histogram,
                      histogram.boundaries == histogramBoundaries,
                      histogram.cumulativeCounts.count == histogramBoundaries.count,
                      histogram.cumulativeCounts == histogram.cumulativeCounts.sorted(),
                      (histogram.cumulativeCounts.last ?? 0) <= histogram.count,
                      histogram.sum.isFinite, histogram.sum >= 0 else {
                    throw HostwrightMetricsError.invalidSeries("\(item.name) histogram shape")
                }
            case .summary:
                let finiteValues = item.summary.map {
                    [$0.minimum, $0.maximum, $0.mean].compactMap { $0 }
                } ?? []
                let orderedBounds = item.summary.map { summary in
                    guard let minimum = summary.minimum, let maximum = summary.maximum else {
                        return true
                    }
                    return minimum <= maximum
                } ?? false
                guard item.value == nil, item.histogram == nil,
                      let summary = item.summary,
                      summary.sum.isFinite, summary.sum >= 0,
                      (summary.count == 0) == (summary.minimum == nil),
                      (summary.count == 0) == (summary.maximum == nil),
                      (summary.count == 0) == (summary.mean == nil),
                      summary.count > 0 || summary.sum == 0,
                      finiteValues.allSatisfy({ $0.isFinite && $0 >= 0 }),
                      orderedBounds else {
                    throw HostwrightMetricsError.invalidSeries("\(item.name) summary shape")
                }
            }
        }
    }

    private static func descriptor(
        _ name: String,
        _ type: HostwrightMetricType,
        _ label: String,
        _ values: [String]
    ) -> HostwrightMetricDescriptor {
        HostwrightMetricDescriptor(name: name, type: type, labels: [label: values.sorted()])
    }
}
