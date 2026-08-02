import XCTest
@testable import HostwrightObservability

final class MetricsContractTests: XCTestCase {
    func testCatalogIsFixedBoundedAndFreeOfUserControlledLabels() {
        XCTAssertEqual(HostwrightMetricCatalog.descriptors.count, 15)
        XCTAssertEqual(
            Set(HostwrightMetricCatalog.descriptors.map(\.name)),
            [
                "hostwright_api_requests_total",
                "hostwright_errors_total",
                "hostwright_gc_decisions_total",
                "hostwright_health_checks_total",
                "hostwright_managed_resources",
                "hostwright_metrics_dropped_samples_total",
                "hostwright_network_resources",
                "hostwright_operation_duration_seconds",
                "hostwright_reconciliation_duration_seconds",
                "hostwright_reconciliation_iterations_total",
                "hostwright_retries_total",
                "hostwright_runtime_actions_total",
                "hostwright_scheduling_decisions_total",
                "hostwright_state_database_bytes",
                "hostwright_storage_resources"
            ]
        )
        XCTAssertEqual(HostwrightMetricCatalog.maximumSeries, 128)
        XCTAssertEqual(HostwrightMetricCatalog.maximumLabelValueBytes, 64)
        XCTAssertEqual(
            HostwrightMetricCatalog.histogramBoundaries,
            [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30]
        )
        let keys = Set(HostwrightMetricCatalog.descriptors.flatMap { $0.labels.keys })
        XCTAssertEqual(keys, ["component", "decision", "outcome", "reason", "resource", "status"])
        XCTAssertFalse(keys.contains("project"))
        XCTAssertFalse(keys.contains("service"))
        XCTAssertFalse(keys.contains("path"))
    }

    func testValidationRejectsUnknownLabelsDuplicateSeriesAndUnboundedCardinality() {
        XCTAssertThrowsError(try HostwrightMetricCatalog.validate([
            HostwrightMetricSeries(
                name: "hostwright_api_requests_total",
                type: .counter,
                labels: ["outcome": "project-secret"],
                value: 1
            )
        ]))
        let valid = HostwrightMetricSeries(
            name: "hostwright_api_requests_total",
            type: .counter,
            labels: ["outcome": "succeeded"],
            value: 1
        )
        XCTAssertThrowsError(try HostwrightMetricCatalog.validate([valid, valid]))
        XCTAssertThrowsError(try HostwrightMetricCatalog.validate(
            Array(repeating: valid, count: HostwrightMetricCatalog.maximumSeries + 1)
        )) { error in
            XCTAssertEqual(error as? HostwrightMetricsError, .seriesBudgetExceeded)
        }
    }

    func testValidationEnforcesHistogramAndSummaryShapes() {
        XCTAssertThrowsError(try HostwrightMetricCatalog.validate([
            HostwrightMetricSeries(
                name: "hostwright_operation_duration_seconds",
                type: .histogram,
                histogram: HostwrightMetricHistogram(
                    boundaries: HostwrightMetricCatalog.histogramBoundaries,
                    cumulativeCounts: Array(repeating: 2, count: 10),
                    count: 1,
                    sum: 1
                )
            )
        ]))
        XCTAssertThrowsError(try HostwrightMetricCatalog.validate([
            HostwrightMetricSeries(
                name: "hostwright_reconciliation_duration_seconds",
                type: .summary,
                summary: HostwrightMetricSummary(
                    count: 0,
                    sum: 0,
                    minimum: 0,
                    maximum: nil,
                    mean: nil
                )
            )
        ]))
    }
}
