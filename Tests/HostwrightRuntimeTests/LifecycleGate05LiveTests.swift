import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class LifecycleGate05LiveTests: XCTestCase {
    func testAppleCLIConfirmedCreateAndDeleteThroughSecureBoundary() async throws {
        guard ProcessInfo.processInfo.environment["HOSTWRIGHT_PHASE04_LIVE"] == "1" else {
            throw XCTSkip("Set HOSTWRIGHT_PHASE04_LIVE=1 on the explicit Phase 04 live cell.")
        }

        let identity = RuntimeServiceIdentity(
            projectName: "phase04-three-service",
            serviceName: "prepare"
        )
        let resourceIdentifier = identity.managedResourceIdentifier
        XCTAssertEqual(
            resourceIdentifier,
            "hostwright-v2-phase04-prepare-fa34c066c811e50c2cf199cfa1d2cb6d"
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image:
                "docker.io/library/python@sha256:" +
                "26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92",
            command: ["python3", "-c", "print('prepared')"]
        )
        let adapter = AppleContainerApplyAdapter()
        let snapshot = try await adapter.capabilitySnapshot()
        let context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: snapshot.canonicalSHA256,
            operationID: "f5b7e197-55e6-85e3-be5b-a55bfa6dd0f4",
            resourceUUID: "ceede8e5-b059-8d8e-8d65-f2d9d7de051d",
            resourceGeneration: 1,
            projectResourceUUID: "cc132af1-9b6b-8405-8db5-91cf5bd1bd50",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "a9e5fdb2-97e6-83e4-878d-46470cad151e"
        )
        let confirmation = RuntimeMutationConfirmation(
            confirmed: true,
            reason: "Explicit Phase 04 live test",
            planHash:
                "f198a1025dfcd587679735738ae65e7852d9da6db796d6ce889ba9772ab41cbf",
            manifestHash:
                "26a3bfe38bd5a25f96cb4b6606606899a6595fca8776562ebda783774d4f72a9",
            context: context
        )

        let create = PlannedRuntimeAction(
            kind: .create,
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            isDestructive: false,
            summary: "Create one explicit Phase 04 live-test container.",
            desiredService: service
        )
        do {
            _ = try await adapter.execute(create, confirmation: confirmation)
        } catch {
            XCTFail("Confirmed Apple CLI create failed before cleanup: \(error)")
            return
        }

        let remove = PlannedRuntimeAction(
            kind: .remove,
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            isDestructive: true,
            summary: "Delete the exact Phase 04 live-test container."
        )
        _ = try await adapter.execute(remove, confirmation: confirmation)
        let inventory = try await adapter.inventory()
        XCTAssertFalse(
            inventory.containers.contains {
                $0.name == resourceIdentifier || $0.runtimeID == resourceIdentifier
            }
        )
    }
}
