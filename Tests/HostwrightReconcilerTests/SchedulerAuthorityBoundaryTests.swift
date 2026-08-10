import XCTest
@testable import HostwrightManifest
@testable import HostwrightReconciler

final class SchedulerAuthorityBoundaryTests: XCTestCase {
    func testMapOnlyAdmissionCannotAuthorizeReconciliationMutation() {
        let resources = HostwrightResources(
            requests: HostwrightResourceSet(cpus: 1, memory: "512MiB"),
            limits: HostwrightResourceSet(cpus: 1, memory: "512MiB")
        )
        let manifest = HostwrightManifest(
            version: 3,
            project: "demo",
            services: [
                HostwrightService(
                    name: "api",
                    image: "example.invalid/api:latest",
                    resources: resources
                )
            ]
        )

        let plan = ReconciliationPlanner().plan(manifest: manifest)

        XCTAssertTrue(plan.includesBlockers)
        let authorityBlocker = plan.issues.first {
            $0.stableDetailKey == "scheduler-authority-unavailable"
        }
        XCTAssertEqual(
            authorityBlocker?.message,
            "Scheduler admission was validated, but no persisted Control 2.2 placement decision and fenced reservation were supplied. Manifest-only admission cannot authorize runtime mutation."
        )
        XCTAssertTrue(
            authorityBlocker?.message.contains("persisted") == true
        )
        XCTAssertTrue(
            authorityBlocker?.message.contains("fenced reservation") == true
        )
    }
}
