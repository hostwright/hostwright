import XCTest
@testable import HostwrightRuntime

final class RuntimeRevisionIdentityTests: XCTestCase {
    func testScopedRevisionIdentifierRetainsLogicalIdentityAndExactOwnership() throws {
        let logical = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api",
            instanceName: "r0"
        )
        let revisionName = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api",
            instanceName: "r0-g2"
        ).managedResourceIdentifier
        let context = mutationContext()

        let labels = try RuntimeManagedResourceIdentity.labels(
            for: logical,
            resourceIdentifier: revisionName,
            context: context
        )

        XCTAssertNotEqual(revisionName, logical.managedResourceIdentifier)
        XCTAssertTrue(
            RuntimeManagedResourceIdentity.isScopedCurrentIdentifier(
                revisionName,
                for: logical
            )
        )
        XCTAssertTrue(
            RuntimeManagedResourceIdentity.labelsMatch(
                labels,
                identity: logical,
                resourceIdentifier: revisionName
            )
        )
        XCTAssertEqual(
            try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: labels,
                expectedProviderID: .appleContainerCLI
            )?.resourceUUID,
            context.resourceUUID
        )
    }

    func testScopedRevisionIdentifierRejectsOtherProjectOrService() {
        let logical = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let otherProject = RuntimeServiceIdentity(
            projectName: "other",
            serviceName: "api",
            instanceName: "g2"
        ).managedResourceIdentifier
        let otherService = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "worker",
            instanceName: "g2"
        ).managedResourceIdentifier

        XCTAssertFalse(
            RuntimeManagedResourceIdentity.isScopedCurrentIdentifier(
                otherProject,
                for: logical
            )
        )
        XCTAssertFalse(
            RuntimeManagedResourceIdentity.isScopedCurrentIdentifier(
                otherService,
                for: logical
            )
        )
        XCTAssertThrowsError(
            try RuntimeManagedResourceIdentity.labels(
                for: logical,
                resourceIdentifier: otherProject,
                context: mutationContext()
            )
        )
    }

    func testCreateCommandBindsScopedRevisionNameAndLabels() throws {
        let logical = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let revisionName = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api",
            instanceName: "candidate-g2"
        ).managedResourceIdentifier
        let desired = DesiredRuntimeService(
            identity: logical,
            image: "example.test/api@sha256:\(String(repeating: "a", count: 64))"
        )
        let spec = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(
                name: "container",
                path: "/usr/bin/container-fixture"
            ),
            desiredService: desired,
            mutationContext: mutationContext(),
            resourceIdentifier: revisionName
        )

        XCTAssertEqual(Array(spec.arguments.prefix(3)), ["create", "--name", revisionName])
        XCTAssertTrue(
            spec.arguments.contains(
                "\(RuntimeManagedResourceIdentity.resourceIdentifierLabel)=\(revisionName)"
            )
        )
        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(spec)
        )
    }

    private func mutationContext() -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "b", count: 64),
            operationID: "phase04-revision-test",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 2,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }
}
