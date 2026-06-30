import HostwrightCore
import HostwrightManifest
import HostwrightRuntime
import HostwrightReconciler

let hostwrightReconcilerSmoke: Void = {
    let planner = ReconciliationPlanner()
    let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
    let desired = DesiredRuntimeState(
        projectName: "demo",
        services: [
            DesiredRuntimeService(identity: identity, image: "ghcr.io/example/web:latest")
        ]
    )
    let observed = ObservedRuntimeState(projectName: "demo", services: [])

    let plan = planner.plan(desired: desired, observed: observed)

    precondition(plan.actions.map(\.kind) == [.create])
    precondition(plan.actions.map(\.identity.serviceName) == ["web"])
    precondition(!plan.includesDestructiveAction)

    let unhealthy = ObservedRuntimeState(
        projectName: "demo",
        services: [
            ObservedRuntimeService(identity: identity, lifecycleState: .running, healthState: .unhealthy)
        ]
    )
    let unhealthyPlan = planner.plan(desired: desired, observed: unhealthy)
    precondition(unhealthyPlan.actions.isEmpty)
    precondition(unhealthyPlan.warnings.contains { $0.contains("unhealthy") })

    let dryRun = ManifestDryRunPlanner.plan(
        for: HostwrightManifest(
            project: "api-local",
            services: [
                HostwrightService(name: "api", image: "ghcr.io/example/api:latest", ports: ["8080:8080"])
            ]
        )
    )
    precondition(!dryRun.mutatesRuntime)
    precondition(dryRun.runtimeObservation.contains("unavailable"))
}()
