import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightState

final class MaintenanceDeferralRepositoryTests: XCTestCase {
    func testDeferralPersistsAcrossReopenAndExactOverrideIsSingleTransition() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo",
            planSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.create, .start],
            firstDeferredAt: "2026-08-01T12:00:00Z",
            deadlineAt: "2026-08-02T12:00:00Z",
            reasonRedacted: "outside window"
        )
        let reopened = SQLiteStateStore(path: fixture.path)
        XCTAssertEqual(try reopened.maintenanceDeferrals.latest(projectID: "project-demo"), record)
        XCTAssertNil(try reopened.maintenanceDeferrals.authorizeOverride(
            projectID: "project-demo",
            expectedConfirmationToken: String(repeating: "c", count: 64),
            reasonRedacted: "urgent repair",
            updatedAt: "2026-08-01T12:01:00Z"
        ))
        let authorized = try XCTUnwrap(reopened.maintenanceDeferrals.authorizeOverride(
            projectID: "project-demo",
            expectedConfirmationToken: record.confirmationToken,
            reasonRedacted: "urgent repair",
            updatedAt: "2026-08-01T12:01:00Z"
        ))
        XCTAssertEqual(authorized.state, .overrideAuthorized)
        XCTAssertNil(try reopened.maintenanceDeferrals.authorizeOverride(
            projectID: "project-demo",
            expectedConfirmationToken: record.confirmationToken,
            reasonRedacted: "duplicate",
            updatedAt: "2026-08-01T12:02:00Z"
        ))
    }

    func testNewPlanSupersedesOnlyCurrentPendingPlanAndCancellationIsExact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo",
            planSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.restart],
            firstDeferredAt: "2026-08-01T12:00:00Z",
            deadlineAt: "2026-08-02T12:00:00Z",
            reasonRedacted: "outside window"
        )
        let second = try fixture.store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo",
            planSHA256: String(repeating: "c", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.restart],
            firstDeferredAt: "2026-08-01T12:05:00Z",
            deadlineAt: "2026-08-02T12:05:00Z",
            reasonRedacted: "new plan"
        )
        let history = try fixture.store.maintenanceDeferrals.history(projectID: "project-demo")
        XCTAssertEqual(history.map(\.state), [.deferred, .superseded, .deferred])
        XCTAssertNil(try fixture.store.maintenanceDeferrals.cancel(
            projectID: "project-demo",
            expectedConfirmationToken: first.confirmationToken,
            updatedAt: "2026-08-01T12:06:00Z"
        ))
        XCTAssertEqual(try fixture.store.maintenanceDeferrals.cancel(
            projectID: "project-demo",
            expectedConfirmationToken: second.confirmationToken,
            updatedAt: "2026-08-01T12:06:00Z"
        )?.state, .cancelled)
    }

    func testExactSupersessionClosesPendingPlanBeforeImmediateAdmission() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pending = try fixture.store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo",
            planSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.create],
            firstDeferredAt: "2026-08-01T12:00:00Z",
            deadlineAt: "2026-08-02T12:00:00Z",
            reasonRedacted: "outside window"
        )
        XCTAssertNil(try fixture.store.maintenanceDeferrals.supersede(
            projectID: "project-demo",
            expectedConfirmationToken: String(repeating: "c", count: 64),
            updatedAt: "2026-08-01T12:01:00Z"
        ))
        let superseded = try XCTUnwrap(fixture.store.maintenanceDeferrals.supersede(
            projectID: "project-demo",
            expectedConfirmationToken: pending.confirmationToken,
            updatedAt: "2026-08-01T12:01:00Z"
        ))
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertNil(try fixture.store.maintenanceDeferrals.supersede(
            projectID: "project-demo",
            expectedConfirmationToken: pending.confirmationToken,
            updatedAt: "2026-08-01T12:02:00Z"
        ))
    }

    func testClockRollbackStillUsesLastDurableTransitionAndTamperingFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let pending = try fixture.store.maintenanceDeferrals.deferPlan(
            projectID: "project-demo_test",
            planSHA256: String(repeating: "a", count: 64),
            policySHA256: String(repeating: "b", count: 64),
            actionClasses: [.create],
            firstDeferredAt: "2026-08-01T12:00:00Z",
            deadlineAt: "2026-08-02T12:00:00Z",
            reasonRedacted: "outside window"
        )
        let cancelled = try XCTUnwrap(fixture.store.maintenanceDeferrals.cancel(
            projectID: "project-demo_test",
            expectedConfirmationToken: pending.confirmationToken,
            updatedAt: "2026-08-01T11:59:00Z"
        ))
        XCTAssertEqual(try fixture.store.maintenanceDeferrals.latest(projectID: "project-demo_test"), cancelled)

        let connection = try SQLiteConnection(path: fixture.path)
        try connection.execute(
            "UPDATE operation_ledger SET payload_json_redacted = replace(payload_json_redacted, '\(pending.confirmationToken)', 'bad') WHERE rowid = (SELECT max(rowid) FROM operation_ledger)"
        )
        XCTAssertThrowsError(try fixture.store.maintenanceDeferrals.latest(projectID: "project-demo_test"))
    }
}

private struct Fixture {
    let root: URL
    let path: String
    let store: SQLiteStateStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        path = root.appendingPathComponent("state.sqlite").path
        store = SQLiteStateStore(path: path)
        try store.migrate()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
