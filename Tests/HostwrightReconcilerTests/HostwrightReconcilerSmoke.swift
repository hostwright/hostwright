import XCTest
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightReconciler

final class HostwrightReconcilerTests: XCTestCase {
    func testPlannerCreatesActionForMissingDesiredServiceWithoutDestructiveAction() {
        let plan = ReconciliationPlanner().plan(desired: desiredState, observed: ObservedRuntimeState(projectName: "demo", services: []))

        XCTAssertEqual(plan.actions.map(\.kind), [.create])
        XCTAssertEqual(plan.actions.map(\.identity.serviceName), ["web"])
        XCTAssertFalse(plan.includesDestructiveAction)
    }

    func testPlannerWarnsForUnhealthyObservedServiceWithoutMutation() {
        let unhealthy = ObservedRuntimeState(
            projectName: "demo",
            services: [
                ObservedRuntimeService(identity: identity, lifecycleState: .running, healthState: .unhealthy)
            ]
        )

        let plan = ReconciliationPlanner().plan(desired: desiredState, observed: unhealthy)

        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("unhealthy") })
    }

    func testPlannerConsumesAdapterShapedObservedStateWithoutMutation() {
        let observed = ObservedRuntimeState(
            projectName: "demo",
            services: [
                ObservedRuntimeService(
                    identity: identity,
                    image: "ghcr.io/example/web:latest",
                    lifecycleState: .running,
                    healthState: .healthy
                )
            ],
            adapterMetadata: RuntimeAdapterMetadata(
                adapterName: "AppleContainerReadOnlyAdapter",
                adapterVersion: "0.0.0-dev",
                runtimeName: "Apple container CLI",
                supportsMutation: false,
                capabilities: [.readOnlyObservation]
            )
        )

        let plan = ReconciliationPlanner().plan(desired: desiredState, observed: observed)

        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testManifestDryRunPlanIsNonMutatingAndRuntimeUnavailable() {
        let dryRun = ManifestDryRunPlanner.plan(
            for: HostwrightManifest(
                project: "api-local",
                services: [
                    HostwrightService(name: "api", image: "ghcr.io/example/api:latest", ports: ["8080:8080"])
                ]
            )
        )

        XCTAssertFalse(dryRun.mutatesRuntime)
        XCTAssertTrue(dryRun.runtimeObservation.contains("unavailable"))
    }

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
    }

    private var desiredState: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [
                DesiredRuntimeService(identity: identity, image: "ghcr.io/example/web:latest")
            ]
        )
    }
}
