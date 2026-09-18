import Foundation
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class StatusObservedAllocationTests: XCTestCase {
    func testStatusJSONPreservesActualAllocationAndOmitsUnavailableValuesThroughHealthCopy() throws {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let manifest = HostwrightManifest(project: "demo", services: [HostwrightService(name: "api", image: "example.local/demo:latest")])
        let desired = DesiredRuntimeState(projectName: "demo", services: [DesiredRuntimeService(
            identity: identity, image: "example.local/demo:latest", cpuCount: 1, memoryBytes: 536_870_912)])
        let store = SQLiteStateStore(path: ":memory:")
        for allocation: RuntimeInventoryAllocation? in [RuntimeInventoryAllocation(cpuCount: 2, memoryBytes: 805_306_368),
                                                        RuntimeInventoryAllocation(cpuCount: 2), nil] {
            let original = ObservedRuntimeState(projectName: "demo", services: [ObservedRuntimeService(
                identity: identity, resourceIdentifier: identity.managedResourceIdentifier, lifecycleState: .running,
                healthState: .unhealthy, allocation: allocation)])
            let observed = try hostwrightPlanningObservedState(observed: original, desiredState: desired, store: store,
                projectID: "demo", currentTimestamp: "2026-09-13T00:00:00Z")
            XCTAssertEqual(observed.services.first?.healthState, .unknown)
            XCTAssertEqual(observed.services.first?.allocation, allocation)
            let output = CLIJSON.statusObserved(manifestPath: "hostwright.yaml", stateDatabasePath: "state.sqlite",
                manifest: manifest, observed: observed,
                plan: ReconciliationPlan(projectName: "demo", observationConnected: true, issues: [], drift: [], actions: []),
                imageDigestLocks: [], portReservations: [], networks: [])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
            let services = try XCTUnwrap(object["services"] as? [[String: Any]])
            let value = try XCTUnwrap(services.first?["observed"] as? [String: Any])
            if let allocation {
                let evidence = try XCTUnwrap(value["allocation"] as? [String: Any])
                XCTAssertEqual(evidence["cpuCount"] as? Int, allocation.cpuCount)
                XCTAssertEqual((evidence["memoryBytes"] as? NSNumber)?.uint64Value, allocation.memoryBytes)
                XCTAssertNil(evidence["storageBytes"])
            } else {
                XCTAssertNil(value["allocation"])
            }
        }
    }
}
