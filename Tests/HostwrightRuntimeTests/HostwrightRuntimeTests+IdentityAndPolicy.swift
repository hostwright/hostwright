import Foundation
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {
    func testVersionedRuntimeIdentifiersAvoidLegacyHyphenCollisions() {
        let first = RuntimeServiceIdentity(projectName: "a-b", serviceName: "c")
        let second = RuntimeServiceIdentity(projectName: "a", serviceName: "b-c")
        let instance = RuntimeServiceIdentity(projectName: "a-b", serviceName: "c", instanceName: "one")

        XCTAssertEqual(first.legacyManagedResourceIdentifier, second.legacyManagedResourceIdentifier)
        XCTAssertNotEqual(first.managedResourceIdentifier, second.managedResourceIdentifier)
        XCTAssertNotEqual(first.managedResourceIdentifier, instance.managedResourceIdentifier)
        XCTAssertEqual(first.managedResourceIdentifier, RuntimeManagedResourceIdentity.resourceIdentifier(for: first))
        XCTAssertLessThanOrEqual(first.managedResourceIdentifier.count, RuntimeManagedResourceIdentity.maximumIdentifierLength)
        XCTAssertTrue(RuntimeManagedResourceIdentity.isCurrentIdentifier(first.managedResourceIdentifier))
        let reservedPrefixLegacy = RuntimeServiceIdentity(projectName: "v2", serviceName: "api").legacyManagedResourceIdentifier
        XCTAssertTrue(RuntimeManagedResourceIdentity.isLegacyIdentifier(reservedPrefixLegacy))
        XCTAssertFalse(RuntimeManagedResourceIdentity.isCurrentIdentifier(reservedPrefixLegacy))
        XCTAssertFalse(RuntimeManagedResourceIdentity.isCurrentIdentifier("hostwright-v2-------x-0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(RuntimeManagedResourceIdentity.isSupportedIdentifier("hostwright-demo-api/../other"))
    }

    func testManagedOwnershipLabelsRoundTripExactUUIDGenerationProviderAndFence() throws {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "operation-label-test",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 2,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
        let labels = try RuntimeManagedResourceIdentity.labels(for: identity, context: context)
        let evidence = try XCTUnwrap(
            RuntimeManagedResourceIdentity.ownershipEvidence(
                from: labels,
                expectedProviderID: .appleContainerCLI
            )
        )

        XCTAssertEqual(evidence.resourceUUID, context.resourceUUID)
        XCTAssertEqual(evidence.projectUUID, context.projectResourceUUID)
        XCTAssertEqual(evidence.resourceGeneration, 2)
        XCTAssertEqual(evidence.projectGeneration, 3)
        XCTAssertEqual(evidence.providerID, .appleContainerCLI)
        XCTAssertEqual(evidence.providerGeneration, 4)
        XCTAssertEqual(evidence.fencingToken, context.fencingToken)

        var partial = labels
        partial.removeValue(forKey: RuntimeManagedResourceIdentity.fencingTokenLabel)
        XCTAssertThrowsError(
            try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: partial,
                expectedProviderID: .appleContainerCLI
            )
        )
    }

    func testRuntimePlanReportsMutationAndDestructiveFlags() {
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
        let plan = RuntimePlan(actions: [
            PlannedRuntimeAction(kind: .create, identity: identity, resourceIdentifier: identity.managedResourceIdentifier, isDestructive: false, summary: "create web")
        ])

        XCTAssertTrue(plan.mutatesRuntime)
        XCTAssertFalse(plan.includesDestructiveAction)
    }

    func testRedactionHandlesSensitiveEnvironmentArgumentsAndJSON() {
        let secretEnvironment = RuntimeEnvironmentValue(name: "API_TOKEN", value: "fake-token-123", isSensitive: true)
        XCTAssertEqual(secretEnvironment.redacted().value, "[REDACTED]")

        let readOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list", "token=fake-token-123"],
            environment: ["PASSWORD": "fake-password"],
            sensitiveValues: ["opaque-session-value"],
            timeout: RuntimeCommandTimeout(seconds: 999),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "fixture"
        )

        XCTAssertEqual(readOnly.timeout.seconds, RuntimeCommandTimeout.maximumSeconds)
        XCTAssertTrue(readOnly.redacted().arguments[1].contains("[REDACTED]"))
        XCTAssertEqual(readOnly.redacted().environment["PASSWORD"], "[REDACTED]")
        XCTAssertFalse(RuntimeRedactionPolicy.default.redact(#""token":"fake-token-123""#).contains("fake-token-123"))

        let redactedResult = RuntimeCommandResult(
            spec: readOnly,
            exitStatus: 0,
            standardOutput: "SESSION=opaque-session-value",
            standardError: "opaque-session-value"
        ).redacted()
        XCTAssertFalse(redactedResult.standardOutput.contains("opaque-session-value"))
        XCTAssertFalse(redactedResult.standardError.contains("opaque-session-value"))
        XCTAssertTrue(redactedResult.spec.sensitiveValues.isEmpty)
    }

    func testRuntimeCommandPolicyAcceptsReadOnlyResolvedSpecs() {
        let readOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "fixture"
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(readOnly))
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyExecution(readOnly))
    }

    func testRuntimeCommandPolicyRejectsMutatingForbiddenAndUnknownSpecs() {
        for rejectedClassification in [RuntimeCommandClassification.mutating, .forbidden, .unknown] {
            let rejected = RuntimeCommandSpec(
                executablePath: "/usr/bin/example",
                arguments: ["not-allowed"],
                classification: rejectedClassification,
                executableResolution: .resolvedByRuntimeExecutableResolver,
                purpose: "fixture"
            )

            XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(rejected))
            XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(rejected))
        }
    }

    func testManagedStartAndDeletePoliciesAcceptOnlyExactHostwrightContainers() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        let start = AppleContainerCommand.spec(kind: .startContainer(containerID: "hostwright-demo-api"), executable: executable)
        let delete = AppleContainerCommand.spec(kind: .deleteContainer(containerID: "hostwright-demo-api"), executable: executable)

        XCTAssertEqual(start.arguments, ["start", "hostwright-demo-api"])
        XCTAssertEqual(start.mutationKind, .startManagedService)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateStartManagedServiceMutation(start))
        XCTAssertEqual(delete.arguments, ["delete", "hostwright-demo-api"])
        XCTAssertEqual(delete.mutationKind, .deleteManagedContainer)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(delete))

        let attachedStart = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["start", "--attach", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            purpose: "fixture"
        )
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateStartManagedServiceMutation(attachedStart))

        let unsafeAttachedStart = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["start", "--attach", "--debug", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateStartManagedServiceMutation(
                unsafeAttachedStart
            )
        )

        let forcedDelete = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete", "--force", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .deleteManagedContainer,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(forcedDelete))

        let nonHostwrightDelete = AppleContainerCommand.spec(kind: .deleteContainer(containerID: "manual-api"), executable: executable)
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateDeleteManagedContainerMutation(nonHostwrightDelete))
    }

    func testManagedRestartPolicyAcceptsOnlyInternalStopThenStartSteps() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture")
        let stop = AppleContainerCommand.spec(kind: .stopForManagedRestart(containerID: "hostwright-demo-api"), executable: executable)
        let start = AppleContainerCommand.spec(kind: .startForManagedRestart(containerID: "hostwright-demo-api"), executable: executable)

        XCTAssertEqual(stop.arguments, ["stop", "hostwright-demo-api"])
        XCTAssertEqual(start.arguments, ["start", "hostwright-demo-api"])
        XCTAssertEqual(stop.mutationKind, .restartManagedService)
        XCTAssertEqual(start.mutationKind, .restartManagedService)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(stop))
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(start))

        let broadRestart = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["restart", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .restartManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(broadRestart))

        let nonHostwrightStop = AppleContainerCommand.spec(kind: .stopForManagedRestart(containerID: "manual-api"), executable: executable)
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateRestartManagedServiceMutation(nonHostwrightStop))

        let wrongKindStop = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["stop", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateStartManagedServiceMutation(wrongKindStop))
    }

    func testReadOnlyExecutionRejectsUnresolvedExecutable() {
        let unresolvedReadOnly = RuntimeCommandSpec(
            executablePath: "/usr/bin/example",
            arguments: ["list"],
            classification: .readOnly,
            purpose: "fixture"
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyCommandClassification(unresolvedReadOnly))
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(unresolvedReadOnly))
    }

    func testCLIReconcilerAndHealthDoNotBypassRuntimeBoundary() throws {
        let runtimeCommandFiles = [
            "Sources/HostwrightCLI/HostwrightCLI.swift",
            "Sources/HostwrightCommand/main.swift",
            "Sources/HostwrightControl/LocalControlAPI.swift",
            "Sources/HostwrightControl/ControlToolCommand.swift",
            "Sources/HostwrightControlTool/main.swift",
            "Sources/HostwrightReconciler/ReconciliationPlanner.swift",
            "Sources/HostwrightHealth/DoctorModels.swift"
        ]

        for file in runtimeCommandFiles {
            let text = try String(contentsOfFile: file, encoding: .utf8)
            XCTAssertFalse(text.contains("AppleContainerCommand"), file)
            XCTAssertFalse(text.contains("AppleContainerReadOnlyAdapter"), file)
            XCTAssertFalse(text.contains("SecureRuntimeProcessRunner"), file)
        }
    }
}
