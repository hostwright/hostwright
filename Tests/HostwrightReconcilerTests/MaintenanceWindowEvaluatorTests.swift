import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightReconciler

final class MaintenanceWindowEvaluatorTests: XCTestCase {
    func testOneShotRequiresEveryElectiveActionAndHonorsDeadlineAndOverride() throws {
        let policy = HostwrightMaintenancePolicy(
            timezone: "UTC",
            maximumDeferral: 3_600,
            windows: [
                HostwrightMaintenanceWindow(
                    id: "release",
                    actions: [.create, .start],
                    schedule: .oneShot(HostwrightOneShotMaintenanceWindow(
                        startsAt: "2026-08-02T04:00:00Z",
                        duration: 1_800
                    ))
                )
            ]
        )
        let before = try date("2026-08-02T03:00:00Z")
        let deferred = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create, .start],
            now: before,
            deferredAt: before
        )
        XCTAssertFalse(deferred.admitted)
        XCTAssertEqual(deferred.reason, .outsideWindow)
        XCTAssertEqual(deferred.nextWindow?.windowID, "release")

        let missingAction = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create, .restart],
            now: try date("2026-08-02T04:05:00Z"),
            deferredAt: before
        )
        XCTAssertFalse(missingAction.admitted)

        let expired = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create],
            now: try date("2026-08-02T05:00:00Z"),
            deferredAt: before
        )
        XCTAssertEqual(expired.reason, .deadlineExpired)

        let override = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create],
            now: try date("2026-08-02T03:30:00Z"),
            deferredAt: before,
            emergencyOverrideAuthorized: true
        )
        XCTAssertTrue(override.admitted)
        XCTAssertEqual(override.reason, .emergencyOverride)

        let staleOverride = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create],
            now: try date("2026-08-02T05:00:00Z"),
            deferredAt: before,
            emergencyOverrideAuthorized: true
        )
        XCTAssertFalse(staleOverride.admitted)
        XCTAssertEqual(staleOverride.reason, .deadlineExpired)

        let exactEnd = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.create],
            now: try date("2026-08-02T04:30:00Z")
        )
        XCTAssertFalse(exactEnd.admitted)
    }

    func testDSTGapUsesFirstRepresentableLaterTime() throws {
        let policy = recurringPolicy(start: "02:30", duration: 3_600)
        let decision = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.restart],
            now: try date("2026-03-08T07:45:00Z")
        )
        XCTAssertTrue(decision.admitted)
        XCTAssertEqual(decision.activeWindow?.startsAt, "2026-03-08T07:30:00Z")
    }

    func testDSTRepeatUsesFirstOccurrenceOnly() throws {
        let policy = recurringPolicy(start: "01:30", duration: 3_600)
        let first = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.restart],
            now: try date("2026-11-01T05:45:00Z")
        )
        XCTAssertTrue(first.admitted)
        XCTAssertEqual(first.activeWindow?.startsAt, "2026-11-01T05:30:00Z")

        let second = MaintenanceWindowEvaluator.evaluate(
            policy: policy,
            actions: [.restart],
            now: try date("2026-11-01T06:45:00Z")
        )
        XCTAssertFalse(second.admitted)
    }

    func testRecoveryAndSecurityStopCannotBeDeferredOrCancelled() throws {
        let policy = recurringPolicy(start: "02:30", duration: 3_600)
        for action in [HostwrightMaintenanceActionClass.recovery, .securityStop] {
            let decision = MaintenanceWindowEvaluator.evaluate(
                policy: policy,
                actions: [action],
                now: try date("2026-08-01T12:00:00Z"),
                cancelled: true
            )
            XCTAssertTrue(decision.admitted)
            XCTAssertEqual(decision.reason, .safetyRecovery)
        }
    }

    private func recurringPolicy(start: String, duration: Int) -> HostwrightMaintenancePolicy {
        HostwrightMaintenancePolicy(
            timezone: "America/New_York",
            windows: [
                HostwrightMaintenanceWindow(
                    id: "sunday",
                    actions: [.restart],
                    schedule: .recurring(HostwrightRecurringMaintenanceWindow(
                        weekdays: [.sunday],
                        start: start,
                        duration: duration
                    ))
                )
            ]
        )
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
