import Foundation
import HostwrightReconciler
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleSchedulerEffectFreshnessTests: XCTestCase {
    func testPressureExpiringAfterCreatePreflightPreventsProviderMutation() throws {
        try assertRejectedAfterPreflight(command: .up, expectedMutations: [])
    }

    func testPressureExpiringAfterStartPreflightAllowsExactCompensatingDeletion() throws {
        try assertRejectedAfterPreflight(
            command: .up, afterCompletedAction: .create, expectedMutations: [.create, .remove]
        )
    }

    func testPressureExpiringAfterRestartPreflightPreventsRestart() throws {
        try assertRejectedAfterPreflight(command: .restart, afterCompletedAction: .stop, expectedMutations: [.stop])
    }

    private func assertRejectedAfterPreflight(
        command: LifecycleCommandKind,
        afterCompletedAction: LifecyclePlanAction? = nil,
        expectedMutations: [PlannedRuntimeActionKind]
    ) throws {
        try withFixture(existingManagedResource: command == .restart) { fixture in
            try fixture.wait {
                await fixture.adapter.useAuthoritativeInventory()
                await fixture.adapter.setPreserveExistingOwnershipFenceOnMutation(true)
            }
            var environment = try fixture.localSchedulerEnvironment()
            let original = try XCTUnwrap(environment.lifecycleScheduler)
            let authority = EffectFreshnessAuthority()
            let store = fixture.store
            try fixture.wait {
                await fixture.adapter.setInventoryObserver {
                    if let afterCompletedAction {
                        guard try store.operationGroupSteps.loadAll().contains(where: {
                            $0.direction == .forward && $0.status == .succeeded &&
                                $0.plannedActionType == afterCompletedAction.rawValue
                        }) else { return }
                    }
                    authority.expireAfterAdmission()
                }
            }
            environment.lifecycleScheduler = LifecycleSchedulerContext(subjectID: original.subjectID) {
                let snapshot = try original.refresh()
                let expired = authority.refresh()
                return LifecycleSchedulerHostSnapshot(
                    capacity: snapshot.capacity,
                    pressure: snapshot.pressure,
                    configDigest: snapshot.configDigest,
                    profileDigest: snapshot.profileDigest,
                    labels: snapshot.labels,
                    observedAt: expired ? Date().addingTimeInterval(-60) : snapshot.observedAt
                )
            }
            let preview = fixture.options(command: command, dryRun: true)
            let previewResult = LifecycleCommandRunner(
                options: preview,
                driver: LifecycleLiveDriver(environment: environment, options: preview)
            ).run()
            XCTAssertEqual(previewResult.exitCode, 0, previewResult.standardError)
            let plan = try JSONDecoder().decode(
                LifecyclePlan.self, from: Data(previewResult.standardOutput.utf8)
            )
            let confirmed = fixture.options(command: command, dryRun: false, confirmation: plan.planSHA256)
            let result = LifecycleCommandRunner(
                options: confirmed,
                driver: LifecycleLiveDriver(environment: environment, options: confirmed)
            ).run()
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertTrue(authority.didExpire, "Authority must expire during provider inventory preflight.")
            XCTAssertEqual(try fixture.adapterSnapshot().mutations, expectedMutations, result.standardError)
            XCTAssertTrue(try fixture.store.schedulerAdmissions.activeReservations().isEmpty)
            if command == .up {
                XCTAssertTrue(try fixture.wait { try await fixture.adapter.inventory() }.containers.isEmpty)
            }
        }
    }
}

private final class EffectFreshnessAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = false
    private var expired = false

    var didExpire: Bool { lock.withLock { expired } }

    func refresh() -> Bool {
        lock.withLock {
            admitted = true
            return expired
        }
    }

    func expireAfterAdmission() {
        lock.withLock { if admitted { expired = true } }
    }
}
