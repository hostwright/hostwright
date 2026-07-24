import Foundation
import HostwrightTestSupport
import Network
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime
@testable import HostwrightSecrets

final class HostwrightRuntimeTests: XCTestCase {
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

    func testAppleContainerSystemStatusUsesExactReadOnlyJSONCommand() {
        let spec = AppleContainerCommand.spec(
            kind: .systemStatus,
            executable: ResolvedRuntimeExecutable(
                name: "container",
                path: "/usr/local/bin/container"
            ),
            timeout: RuntimeCommandTimeout(seconds: 15)
        )

        XCTAssertEqual(spec.arguments, ["system", "status", "--format", "json"])
        XCTAssertEqual(spec.classification, .readOnly)
        XCTAssertEqual(spec.exitStatusPolicy, .appleContainerSystemStatus)
        XCTAssertEqual(spec.timeout.seconds, 15)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyExecution(spec))
    }

    func testAppleContainerSystemStatusExitPolicyIsExactAndReadOnly() {
        let unrelated = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["list"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(unrelated))

        let mutating = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["system", "status", "--format", "json"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateSupportedMutation(mutating))
    }

    func testAppleContainerSystemStatusParserIsBoundedAndStrictAboutReadiness() throws {
        let running = try AppleContainerSystemStatusParser.parse(
            #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
            cliVersion: "container CLI version 1.1.0\n"
        )
        XCTAssertEqual(running.serviceState, .running)
        XCTAssertEqual(running.cliVersion, "1.1.0")
        XCTAssertEqual(running.serviceVersion, "1.1.0")
        XCTAssertEqual(running.serviceBuild, "release")

        let stopped = try AppleContainerSystemStatusParser.parse(
            #"{"status":"not running","apiServerVersion":"","apiServerBuild":""}"#,
            cliVersion: "container CLI version 1.1.0"
        )
        XCTAssertEqual(stopped.serviceState, .notRunning)
        XCTAssertNil(stopped.serviceVersion)

        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"starting","apiServerVersion":"","apiServerBuild":""}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                String(repeating: "x", count: AppleContainerSystemStatusParser.maximumBytes + 1),
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","status":"not running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release\nforged"}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
                cliVersion: String(repeating: "x", count: 1_025) + " version 1.1.0"
            )
        )
    }

    func testAppleContainerReadinessRunsVersionAndServiceProbesThroughRuntimeBoundary() async throws {
        let executable = "/usr/local/bin/container"
        let runner = RoutingRuntimeProcessRunner { spec in
            let output: String
            let exitStatus: Int32
            switch spec.arguments {
            case ["--version"]:
                output = "container CLI version 1.1.0\n"
                exitStatus = 0
            case ["system", "status", "--format", "json"]:
                output = #"{"status":"not running","apiServerVersion":"","apiServerBuild":""}"#
                exitStatus = 1
            default:
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected readiness command"
                )
            }
            return RuntimeCommandResult(
                spec: spec,
                exitStatus: exitStatus,
                standardOutput: output,
                standardError: ""
            )
        }
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [AppleContainerCommand.executableName: executable]
            ),
            processRunner: runner
        )

        let readiness = try await adapter.runtimeReadiness()

        XCTAssertEqual(readiness.serviceState, .notRunning)
        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["system", "status", "--format", "json"]]
        )
        XCTAssertTrue(runner.calls.allSatisfy { $0.classification == .readOnly })
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

    func testCreateMissingServiceMutationPolicyAcceptsOnlyResolvedCreateSpecs() throws {
        let create = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )

        XCTAssertNoThrow(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(create))
        XCTAssertEqual(create.classification, .mutating)
        XCTAssertEqual(create.mutationKind, .createMissingService)
        XCTAssertEqual(create.arguments.prefix(3), ["create", "--name", identity.managedResourceIdentifier])
        XCTAssertTrue(create.arguments.contains("--label"))
        XCTAssertTrue(create.arguments.contains("\(RuntimeManagedResourceIdentity.managedLabel)=true"))
        XCTAssertTrue(create.arguments.contains("--publish"))
        XCTAssertTrue(create.arguments.contains("127.0.0.1:8080:8080"))
        XCTAssertFalse(create.arguments.contains("run"))
        XCTAssertFalse(create.arguments.contains("--rm"))

        let unresolved = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create"],
            classification: .mutating,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unresolved))

        let forbidden = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete"],
            classification: .forbidden,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(forbidden))

        let mislabeledDelete = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["delete", "hostwright-demo-api"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(mislabeledDelete))

        let nonHostwrightCreate = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: ["create", "--name", "manual-api", "local/demo:latest"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(nonHostwrightCreate))
    }

    func testCreateMissingServiceMutationPolicyRejectsPreImageFlagsAndAllowsLiteralWorkloadArguments() throws {
        let valid = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )
        let imageIndex = valid.arguments.firstIndex(of: desiredService.image)!
        var unsafeImageArguments = valid.arguments
        unsafeImageArguments[imageIndex] = "--mount=src=/,dst=/host"
        let unsafeImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: unsafeImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(unsafeImage)) { error in
            XCTAssertTrue(String(describing: error).contains("image"))
        }

        var badImageArguments = valid.arguments
        badImageArguments[imageIndex] = "-bad"
        let badImage = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: badImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(badImage))

        let literalWorkloadArguments = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: valid.arguments + ["--network", "literal-network", "--name", "literal-name"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                literalWorkloadArguments
            )
        )

        var preImageArguments = valid.arguments
        preImageArguments.insert("--network", at: imageIndex)
        let unsupportedCreateOption = RuntimeCommandSpec(
            executablePath: "/usr/bin/container-fixture",
            arguments: preImageArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "fixture"
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                unsupportedCreateOption
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("unsupported create option"))
        }
    }

    func testCreateMissingServiceMutationPolicyPermitsOnlyBoundedNonreservedUserLabels() throws {
        func spec(labels: [String: String]) throws -> RuntimeCommandSpec {
            try AppleContainerCommand.spec(
                kind: .createContainer,
                executable: ResolvedRuntimeExecutable(
                    name: "container",
                    path: "/usr/bin/container-fixture"
                ),
                desiredService: DesiredRuntimeService(
                    identity: identity,
                    image: desiredService.image,
                    command: desiredService.command,
                    labels: labels
                ),
                mutationContext: mutationContext
            )
        }

        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(labels: ["com.example.role": "api"])
            )
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(labels: ["dev.hostwright.unexpected": "true"])
            )
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                spec(
                    labels: [
                        "com.example.oversized":
                            String(
                                repeating: "x",
                                count: RuntimeInventoryLimits.maximumStringBytes + 1
                            )
                    ]
                )
            )
        )
    }

    func testCreateMissingServiceMutationPolicyRejectsTamperedOwnershipBinding() throws {
        let valid = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container-fixture"),
            desiredService: desiredService,
            mutationContext: mutationContext
        )
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(valid))

        var tamperedArguments = valid.arguments
        let resourceLabelPrefix = "\(RuntimeManagedResourceIdentity.resourceIdentifierLabel)="
        let labelIndex = tamperedArguments.firstIndex { $0.hasPrefix(resourceLabelPrefix) }!
        tamperedArguments[labelIndex] = "\(resourceLabelPrefix)\(RuntimeServiceIdentity(projectName: "other", serviceName: "api").managedResourceIdentifier)"
        let tampered = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: tamperedArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "tampered ownership fixture"
        )

        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(tampered)) { error in
            XCTAssertTrue(String(describing: error).contains("ownership labels bound to the exact container identifier"))
        }

        var duplicateNameArguments = valid.arguments
        let nameIndex = duplicateNameArguments.firstIndex(of: "--name")!
        duplicateNameArguments.insert(
            contentsOf: ["--name", RuntimeServiceIdentity(projectName: "other", serviceName: "api").managedResourceIdentifier],
            at: nameIndex + 2
        )
        let duplicateName = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: duplicateNameArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "duplicate name fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateCreateMissingServiceMutation(duplicateName)) { error in
            XCTAssertTrue(String(describing: error).contains("exactly one"))
        }

        var duplicateLabelArguments = valid.arguments
        let firstLabelOptionIndex = try XCTUnwrap(
            duplicateLabelArguments.firstIndex(of: "--label")
        )
        duplicateLabelArguments.insert(
            contentsOf: [
                "--label",
                duplicateLabelArguments[firstLabelOptionIndex + 1]
            ],
            at: firstLabelOptionIndex + 2
        )
        let duplicateLabel = RuntimeCommandSpec(
            executablePath: valid.executablePath,
            arguments: duplicateLabelArguments,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .createMissingService,
            purpose: "duplicate label fixture"
        )
        XCTAssertThrowsError(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                duplicateLabel
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("duplicate ownership label"))
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

    func testScriptedRuntimeAdapterCanObserveServices() async throws {
        let observedService = ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: identity.managedResourceIdentifier,
            image: "ghcr.io/example/api:latest",
            lifecycleState: .running,
            healthState: .healthy
        )
        let adapter = ScriptedRuntimeAdapter(scenario: .observed([observedService]))

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].lifecycleState, .running)
    }

    func testScriptedRuntimeAdapterPlansMissingServicesWithoutExecuting() async throws {
        let adapter = ScriptedRuntimeAdapter(scenario: .availableEmpty)
        let observed = try await adapter.observe(desiredState: desiredState)

        let plan = try await adapter.plan(desiredState: desiredState, observedState: observed)

        XCTAssertEqual(plan.actions.map(\.kind), [.create])
    }

    func testScriptedRuntimeAdapterRedactsFailureOutput() async {
        let adapter = ScriptedRuntimeAdapter(scenario: .redactedFailure("password=fake-password token=fake-token"))

        do {
            _ = try await adapter.observe(desiredState: desiredState)
            XCTFail("Expected redacted command failure.")
        } catch let error as RuntimeAdapterError {
            guard case .commandFailed(_, _, let standardError) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertFalse(standardError.contains("fake-password"))
            XCTAssertFalse(standardError.contains("fake-token"))
            XCTAssertTrue(standardError.contains("[REDACTED]"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

    }

    func testSecureRuntimeProcessRunnerDrainsLargeStdout() async throws {
        let runner = SecureRuntimeProcessRunner()
        let result = try await runner.run(processSpec(
            executablePath: "/usr/bin/jot",
            arguments: ["-b", "x", "70000"]
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 65_536)
    }

    func testSecureRuntimeProcessRunnerCapturesFailedCommandStderr() async {
        let runner = SecureRuntimeProcessRunner()
        do {
            _ = try await runner.run(processSpec(
                executablePath: "/usr/bin/swiftc",
                arguments: ["--hostwright-invalid-option"]
            ))
            XCTFail("Expected command failure.")
        } catch let error as RuntimeAdapterError {
            guard case .commandFailed(let status, _, let standardError) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(standardError.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testSecureRuntimeProcessRunnerReturnsAppleStatusExitOneForTypedParsing() async throws {
        let spec = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["system", "status", "--format", "json"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "exercise the Apple system-status exit contract"
        )

        let result = try await SecureRuntimeProcessRunner().run(spec)

        XCTAssertEqual(result.exitStatus, 1)
    }

    func testSecureRuntimeProcessRunnerObservesRepeatedRapidProcessTermination() async throws {
        let runner = SecureRuntimeProcessRunner()
        for sequence in 0..<25 {
            let result = try await runner.run(processSpec(
                executablePath: "/usr/bin/printf",
                arguments: ["%s", String(sequence)]
            ))
            XCTAssertEqual(result.exitStatus, 0)
            XCTAssertEqual(result.standardOutput, String(sequence))
        }
    }

    func testSecureRuntimeProcessRunnerRejectsShellExecutables() async {
        let runner = SecureRuntimeProcessRunner()
        do {
            _ = try await runner.run(processSpec(
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 0"]
            ))
            XCTFail("Expected secure executable rejection.")
        } catch let error as RuntimeAdapterError {
            guard case .permissionDenied(let message) = error else {
                return XCTFail("Expected permissionDenied, got \(error).")
            }
            XCTAssertTrue(message.contains("secure identity"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testSecureRuntimeProcessRunnerCarriesSensitiveValuesOutsideArgvAndRedactsOutput() async throws {
        let opaqueSecret = "opaque-runtime-environment-value"
        let spec = RuntimeCommandSpec(
            executablePath: "/usr/bin/printenv",
            arguments: ["SESSION"],
            environment: ["SESSION": opaqueSecret],
            sensitiveValues: [opaqueSecret],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Verify bounded sensitive environment transport."
        )

        XCTAssertFalse(spec.arguments.joined(separator: " ").contains(opaqueSecret))
        let result = try await SecureRuntimeProcessRunner().run(spec)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.standardOutput.contains(opaqueSecret))
        XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
        XCTAssertFalse(result.spec.environment.values.contains(opaqueSecret))
    }

    func testSecureRuntimeProcessRunnerReportsTimeoutAndCancellationSeparately() async {
        let runner = SecureRuntimeProcessRunner()

        do {
            _ = try await runner.run(processSpec(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: 1
            ))
            XCTFail("Expected timeout.")
        } catch let error as RuntimeAdapterError {
            guard case .commandTimedOut(_, let partialOutput, _) = error else {
                return XCTFail("Expected commandTimedOut, got \(error).")
            }
            XCTAssertTrue(partialOutput.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

        let cancellationSpec = processSpec(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: 10
        )
        let task = Task { try await runner.run(cancellationSpec) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch let error as RuntimeAdapterError {
            guard case .commandCancelled = error else {
                return XCTFail("Expected commandCancelled, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testRuntimeMutationRemainsUnavailable() async {
        let adapter = ScriptedRuntimeAdapter(scenario: .availableEmpty)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .start, identity: identity, resourceIdentifier: identity.managedResourceIdentifier, isDestructive: false, summary: "start"),
                confirmation: nil
            )
            XCTFail("Expected mutation unavailable.")
        } catch let error as RuntimeAdapterError {
            guard case .mutationUnavailableByPolicy = error else {
                return XCTFail("Expected mutationUnavailableByPolicy, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testBoundedHealthCheckerRunsAllowedLoopbackURLAndRedactsOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200, body: "ok token=fake-secret"))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(
                command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"],
                timeoutSeconds: 2
            )
        )

        XCTAssertEqual(result.status, .healthy)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(fetcher.requests.map(\.url.absoluteString), ["http://localhost:8080/health?token=fake-secret"])
        XCTAssertEqual(fetcher.requests.map(\.timeout.seconds), [2])
        XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
        XCTAssertFalse(result.standardOutput.contains("fake-secret"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
    }

    func testURLSessionHealthFetcherRejectsRedirects() async throws {
        let delegate = RejectingRedirectDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalURL = try XCTUnwrap(URL(string: "http://localhost:8080/health"))
        let redirectedURL = try XCTUnwrap(URL(string: "http://example.com/health"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let request = URLRequest(url: redirectedURL)

        let redirectedRequest = await delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request
        )

        XCTAssertNil(redirectedRequest)
        session.invalidateAndCancel()
    }

    func testURLSessionHealthFetcherReadsRealLoopbackHTTPResponse() async throws {
        let server = try LoopbackHTTPServer(statusCode: 200, body: "ready")
        defer { server.stop() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/health"))

        let response = try await URLSessionRuntimeHealthURLFetcher().fetch(
            url: url,
            timeout: RuntimeCommandTimeout(seconds: 2)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "ready")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testURLSessionHealthFetcherRejectsNonLoopbackURLBeforeNetwork() async throws {
        let fetcher = URLSessionRuntimeHealthURLFetcher()
        let url = try XCTUnwrap(URL(string: "https://example.com/health"))

        do {
            _ = try await fetcher.fetch(url: url, timeout: RuntimeCommandTimeout(seconds: 1))
            XCTFail("Expected non-loopback health URL to be rejected.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected(let classification, let message) = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
            XCTAssertEqual(classification, .readOnly)
            XCTAssertTrue(message.contains("loopback"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testBoundedHealthCheckerTreatsRedirectStatusAsUnhealthy() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 302))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health"])
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertEqual(result.exitStatus, 302)
        XCTAssertTrue(result.standardError.contains("HTTP status 302"))
    }

    func testBoundedHealthCheckerRejectsUnsafeCurlAndWgetArgumentsWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )
        let rejectedCommands = [
            ["curl", "-K", "/tmp/curlrc", "http://localhost:8080/health"],
            ["curl", "-o", "/tmp/output", "http://localhost:8080/health"],
            ["curl", "file:///etc/passwd"],
            ["curl", "http://example.com/health"],
            ["wget", "--post-file=/etc/passwd", "http://localhost:8080/health"],
            ["wget", "http://localhost:8080/health"]
        ]

        for command in rejectedCommands {
            let result = await checker.check(identity: identity, spec: RuntimeHealthCheckSpec(command: command))
            XCTAssertEqual(result.status, .unknown)
            XCTAssertTrue(result.standardError.contains("health checks") || result.standardError.contains("Health check URLs"))
        }
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerRejectsShellExecutableWithoutRunning() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(response: RuntimeHealthURLResponse(statusCode: 200))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["sh", "-c", "rm -rf /tmp/hostwright"])
        )

        XCTAssertEqual(result.status, .unknown)
        XCTAssertTrue(result.standardError.contains("not allowed"))
        XCTAssertEqual(fetcher.requests.count, 0)
    }

    func testBoundedHealthCheckerMapsTimeoutToUnhealthyAndRedactsPartialOutput() async {
        let fetcher = RecordingRuntimeHealthURLFetcher(error: URLError(.timedOut))
        let checker = BoundedRuntimeHealthChecker(
            urlFetcher: fetcher
        )

        let result = await checker.check(
            identity: identity,
            spec: RuntimeHealthCheckSpec(command: ["curl", "-f", "http://localhost:8080/health?token=fake-secret"], timeoutSeconds: 1)
        )

        XCTAssertEqual(result.status, .unhealthy)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertTrue(result.standardError.contains("timed out"))
        XCTAssertFalse(result.command.joined(separator: " ").contains("fake-secret"))
        XCTAssertFalse(result.standardError.contains("fake-password"))
    }

    func testAppleContainerApplyAdapterCreatesOnlyWhenLocalImageIsAvailable() async throws {
        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let imageObservations = ObservationFixtureSequence(outputs: [
            imageListFixture,
            try fixture("apple-container-1.1.0-image-list.json")
        ])
        let createdFixture = try containerListOutput(
            identity: proofIdentity,
            state: "stopped",
            context: proofObservationMutationContext
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: imageObservations.next(), standardError: "")
            }
            if spec.arguments.first == "create" {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "created token=fake-token", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: createdFixture, standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let event = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .create,
                identity: proofIdentity,
                resourceIdentifier: proofIdentity.managedResourceIdentifier,
                isDestructive: false,
                summary: "create",
                desiredService: proofService
            ),
            confirmation: mutationConfirmation(context: proofObservationMutationContext)
        )

        XCTAssertEqual(
            runner.calls.compactMap(\.arguments.first),
            ["image", "create", "list", "image"]
        )
        XCTAssertEqual(event.resourceIdentifier, proofIdentity.managedResourceIdentifier)
        XCTAssertFalse(event.message.contains("fake-token"))
        XCTAssertTrue(event.message.contains("verified"))
    }

    func testAppleContainerApplyAdapterRejectsIdentitylessMutationContextBeforeRuntimeAccess() async {
        let adapter = AppleContainerApplyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(executables: [:]),
            processRunner: ScriptedRuntimeProcessRunner(behavior: .failure(.runtimeUnavailable("must not run")))
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .start,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "start"
                ),
                confirmation: RuntimeMutationConfirmation(confirmed: true, reason: "test", planHash: "plan-hash")
            )
            XCTFail("Expected an identity-less mutation context to fail closed.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected(classification: .mutating, message: let message) = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
            XCTAssertTrue(message.contains("Runtime Provider API v2"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterKeepsSensitiveEnvironmentValuesOutOfArgv() async throws {
        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let imageObservations = ObservationFixtureSequence(outputs: [
            imageListFixture,
            try fixture("apple-container-1.1.0-image-list.json")
        ])
        let opaqueSecret = "opaque-session-value"
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            environment: [RuntimeEnvironmentValue(name: "SESSION", value: opaqueSecret, isSensitive: true)],
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80, bindAddress: "127.0.0.1")]
        )
        let createdFixture = try containerListOutput(
            identity: proofIdentity,
            state: "stopped",
            context: proofObservationMutationContext
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: imageObservations.next(), standardError: "")
            }
            if spec.arguments.first == "create" {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "created \(opaqueSecret)", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: createdFixture, standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .create, identity: proofIdentity, resourceIdentifier: proofIdentity.managedResourceIdentifier, isDestructive: false, summary: "create", desiredService: service),
            confirmation: mutationConfirmation(context: proofObservationMutationContext)
        )

        let createSpec = try XCTUnwrap(runner.calls.first { $0.arguments.first == "create" })
        XCTAssertTrue(createSpec.arguments.contains("SESSION"))
        XCTAssertFalse(createSpec.arguments.joined(separator: " ").contains(opaqueSecret))
        XCTAssertEqual(createSpec.environment, ["SESSION": opaqueSecret])
        XCTAssertFalse(createSpec.redacted().environment.values.contains(opaqueSecret))
        XCTAssertTrue(createSpec.arguments.contains("127.0.0.1:18080:80"))
        XCTAssertFalse(event.message.contains(opaqueSecret))
        XCTAssertTrue(event.message.contains("verified"))
    }

    func testAppleContainerApplyAdapterRejectsUnresolvedSecretReferences() async throws {
        let reference = try HostwrightSecretReference.parse("keychain://hostwright.api/api-token")
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            environment: [RuntimeEnvironmentValue(name: "API_TOKEN", value: reference.redactedDescription, isSensitive: true, secretReference: reference)],
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80, bindAddress: "127.0.0.1")]
        )
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: RoutingRuntimeProcessRunner { spec in
            XCTFail("Unresolved secret refs must fail before runtime command execution, got \(spec.arguments).")
            return RuntimeCommandResult(spec: spec, exitStatus: 1, standardOutput: "", standardError: "")
        })

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .create, identity: proofIdentity, resourceIdentifier: proofIdentity.managedResourceIdentifier, isDestructive: false, summary: "create", desiredService: service),
                confirmation: mutationConfirmation()
            )
            XCTFail("Expected unresolved secret reference rejection.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("unresolved secret references"))
            XCTAssertFalse(String(describing: error).contains("hostwright.api"))
            XCTAssertFalse(String(describing: error).contains("api-token"))
        }
    }

    func testAppleContainerApplyAdapterStartsManagedServiceOnly() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let runningFixture = try containerListOutput(
            identity: identity,
            state: "running",
            context: mutationContext
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["start", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "started token=fake-token", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: runningFixture, standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .start, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: false, summary: "start"),
            confirmation: mutationConfirmation(context: mutationContext)
        )

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["start", resourceIdentifier], ["list", "--all", "--format", "json"]]
        )
        XCTAssertEqual(event.resourceIdentifier, resourceIdentifier)
        XCTAssertFalse(event.message.contains("fake-token"))
    }

    func testAppleContainerApplyAdapterCompletionStartAttachesAndRequiresExitedObservation() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let exitedFixture = try containerListOutput(
            identity: identity,
            state: "stopped",
            context: mutationContext,
            startedDate: "2026-07-23T16:00:00Z"
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["start", "--attach", resourceIdentifier] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: "completed",
                    standardError: ""
                )
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: exitedFixture,
                    standardError: ""
                )
            }
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "unexpected command"
            )
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        _ = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .start,
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                isDestructive: false,
                requiresProcessCompletion: true,
                summary: "start-and-complete"
            ),
            confirmation: mutationConfirmation(context: mutationContext)
        )

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["start", "--attach", resourceIdentifier],
                ["list", "--all", "--format", "json"]
            ]
        )
    }

    func testAppleContainerApplyAdapterCompletionStartRejectsFailedExit() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["start", "--attach", resourceIdentifier] {
                throw RuntimeAdapterError.commandFailed(
                    exitStatus: 7,
                    message: "init process failed",
                    standardError: "exit 7"
                )
            }
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "observation must not convert a failed exit into success"
            )
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .start,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: false,
                    requiresProcessCompletion: true,
                    summary: "start-and-complete"
                ),
                confirmation: mutationConfirmation(context: mutationContext)
            )
            XCTFail("Expected nonzero completion exit to fail.")
        } catch let error as RuntimeAdapterError {
            guard case .commandFailed(let status, _, _) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertEqual(status, 7)
        }
    }

    func testAppleContainerApplyAdapterDeletesOnlyExplicitDestructiveManagedContainer() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["delete", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "deleted", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "[]", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .remove, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: true, summary: "delete"),
            confirmation: mutationConfirmation(planHash: "cleanup-token", context: mutationContext)
        )

        XCTAssertEqual(event.resourceIdentifier, resourceIdentifier)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .remove, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: false, summary: "delete"),
                confirmation: mutationConfirmation(planHash: "cleanup-token", context: mutationContext)
            )
            XCTFail("Expected non-destructive delete action to be rejected.")
        } catch let error as RuntimeAdapterError {
            guard case .commandRejected = error else {
                return XCTFail("Expected commandRejected, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterRestartsManagedServiceWithStopThenStartOnly() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let observations = ObservationFixtureSequence(outputs: [
            try containerListOutput(identity: identity, state: "running", context: mutationContext),
            try containerListOutput(identity: identity, state: "stopped", context: mutationContext),
            try containerListOutput(identity: identity, state: "running", context: mutationContext)
        ])
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["stop", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "stopped token=fake-token", standardError: "")
            }
            if spec.arguments == ["start", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "started token=fake-token", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: observations.next(), standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .restart, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: true, summary: "restart"),
            confirmation: mutationConfirmation(context: mutationContext)
        )

        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["list", "--all", "--format", "json"],
                ["stop", resourceIdentifier],
                ["list", "--all", "--format", "json"],
                ["start", resourceIdentifier],
                ["list", "--all", "--format", "json"]
            ]
        )
        XCTAssertEqual(event.resourceIdentifier, resourceIdentifier)
        XCTAssertTrue(event.message.contains("verified"))
        XCTAssertFalse(event.message.contains("fake-token"))
    }

    func testAppleContainerApplyAdapterReportsPartialManagedRestartWhenStartFailsAfterStop() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let observations = ObservationFixtureSequence(outputs: [
            try containerListOutput(identity: identity, state: "running", context: mutationContext),
            try containerListOutput(identity: identity, state: "stopped", context: mutationContext)
        ])
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["stop", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "stopped", standardError: "")
            }
            if spec.arguments == ["start", resourceIdentifier] {
                throw RuntimeAdapterError.commandFailed(exitStatus: 2, message: "start failed", standardError: "token=fake-token")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: observations.next(), standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .restart, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: true, summary: "restart"),
                confirmation: mutationConfirmation(context: mutationContext)
            )
            XCTFail("Expected partial restart failure.")
        } catch let error as RuntimeAdapterError {
            guard case .managedRestartStartFailedAfterStop(let message, let standardError) = error else {
                return XCTFail("Expected managedRestartStartFailedAfterStop, got \(error).")
            }
            XCTAssertTrue(message.contains("start failed"))
            XCTAssertTrue(standardError.contains("[REDACTED]"))
            XCTAssertFalse(standardError.contains("fake-token"))
            XCTAssertEqual(
                runner.calls.map(\.arguments),
                [
                    ["list", "--all", "--format", "json"],
                    ["stop", resourceIdentifier],
                    ["list", "--all", "--format", "json"],
                    ["start", resourceIdentifier]
                ]
            )
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterRestartsStoppedAndExitedServicesWithStartOnly() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let cases: [(name: String, startedDate: String?)] = [
            ("stopped", nil),
            ("exited", "2026-07-23T16:00:00Z")
        ]

        for fixture in cases {
            let observations = ObservationFixtureSequence(outputs: [
                try containerListOutput(
                    identity: identity,
                    state: "stopped",
                    context: mutationContext,
                    startedDate: fixture.startedDate
                ),
                try containerListOutput(
                    identity: identity,
                    state: "running",
                    context: mutationContext
                )
            ])
            let runner = RoutingRuntimeProcessRunner { spec in
                if spec.arguments == ["start", resourceIdentifier] {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: "started",
                        standardError: ""
                    )
                }
                if spec.arguments == ["list", "--all", "--format", "json"] {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: observations.next(),
                        standardError: ""
                    )
                }
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected command"
                )
            }
            let adapter = AppleContainerApplyAdapter(
                executableResolver: resolvedContainer,
                processRunner: runner
            )

            let event = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .restart,
                    identity: identity,
                    resourceIdentifier: resourceIdentifier,
                    isDestructive: true,
                    summary: "restart"
                ),
                confirmation: mutationConfirmation(context: mutationContext)
            )

            XCTAssertEqual(
                runner.calls.map(\.arguments),
                [
                    ["list", "--all", "--format", "json"],
                    ["start", resourceIdentifier],
                    ["list", "--all", "--format", "json"]
                ],
                fixture.name
            )
            XCTAssertEqual(event.resourceIdentifier, resourceIdentifier, fixture.name)
        }
    }

    func testAppleContainerReadOnlyAdapterReadsTailLogsWithoutFollowAttachOrExec() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTAssertEqual(spec.arguments, ["logs", "-n", "25", resourceIdentifier])
            XCTAssertFalse(spec.arguments.contains("--follow"))
            XCTAssertFalse(spec.arguments.contains("--attach"))
            XCTAssertFalse(spec.arguments.contains("exec"))
            return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "token=fake-token\nready", standardError: "")
        }
        let adapter = AppleContainerReadOnlyAdapter(executableResolver: resolvedContainer, processRunner: runner)
        let observedService = ObservedRuntimeService(
            identity: identity,
            resourceIdentifier: resourceIdentifier,
            lifecycleState: .running
        )

        let logs = try await adapter.logs(for: observedService, tail: 25)

        XCTAssertEqual(logs.lineLimit, 25)
        XCTAssertTrue(logs.text.contains("[REDACTED]"))
        XCTAssertFalse(logs.text.contains("fake-token"))
    }


    func testAppleContainerApplyAdapterRejectsMissingLocalImageBeforeCreate() async {
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "[]", standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "create should not run")
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "create",
                    desiredService: desiredService
                ),
                confirmation: mutationConfirmation()
            )
            XCTFail("Expected local image availability failure.")
        } catch let error as RuntimeAdapterError {
            guard case .capabilityUnavailable(.lifecycleMutation) = error else {
                return XCTFail("Expected lifecycleMutation capabilityUnavailable, got \(error).")
            }
            XCTAssertEqual(runner.calls.count, 1)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerApplyAdapterRejectsUnsupportedCreateSubsets() async {
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: RoutingRuntimeProcessRunner { _ in
                throw RuntimeAdapterError.commandFailed(exitStatus: 1, message: "should not run", standardError: "")
            }
        )
        let mounted = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            mounts: [RuntimeMountReference(source: "./data", target: "/data")]
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(kind: .create, identity: identity, resourceIdentifier: identity.managedResourceIdentifier, isDestructive: false, summary: "create", desiredService: mounted),
                confirmation: mutationConfirmation()
            )
            XCTFail("Expected unsupported subset failure.")
        } catch let error as RuntimeAdapterError {
            guard case .mutationUnavailableByPolicy(let message) = error else {
                return XCTFail("Expected mutationUnavailableByPolicy, got \(error).")
            }
            XCTAssertTrue(message.contains("bind mounts"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: identity,
                    resourceIdentifier: identity.legacyManagedResourceIdentifier,
                    isDestructive: false,
                    summary: "tampered create",
                    desiredService: desiredService
                ),
                confirmation: mutationConfirmation()
            )
            XCTFail("Expected tampered create identity rejection.")
        } catch let error as RuntimeAdapterError {
            guard case .mutationUnavailableByPolicy(let message) = error else {
                return XCTFail("Expected mutationUnavailableByPolicy, got \(error).")
            }
            XCTAssertTrue(message.contains("exact desired identity"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerReadOnlyAdapterMissingExecutableDegradesHonestly() async {
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(executables: [:]),
            processRunner: ScriptedRuntimeProcessRunner(behavior: .failure(.runtimeUnavailable("should not run")))
        )

        do {
            _ = try await adapter.observe(desiredState: desiredState)
            XCTFail("Expected missing executable to fail.")
        } catch let error as RuntimeAdapterError {
            guard case .runtimeUnavailable(let message) = error else {
                return XCTFail("Expected runtimeUnavailable, got \(error).")
            }
            XCTAssertTrue(message.contains("not found"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testAppleContainerParserParsesEmptyFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-list-empty-real-json.txt")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.adapterMetadata?.supportsMutation, false)
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserParsesRealEmptyJSONFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-list-empty-real-json.txt")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, desiredState.projectName)
        XCTAssertEqual(AppleContainerCommand.arguments(for: .listContainers), ["list", "--all", "--format", "json"])
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserIgnoresRealBuilderContainerFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: structuredBuilderContainerOutput()
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: proofDesiredState)

        XCTAssertTrue(observed.services.isEmpty)
        XCTAssertEqual(observed.projectName, "proof")
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserParsesRealCreatedProofContainerFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: structuredProofContainerOutput()
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: proofDesiredStateWithExactOwnership)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity, proofIdentity)
        XCTAssertEqual(observed.services[0].image, "hostwright-proof-web:create-only")
        XCTAssertEqual(observed.services[0].lifecycleState, .stopped)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 18080)
        XCTAssertEqual(observed.services[0].ports.first?.containerPort, 80)
        XCTAssertEqual(observed.services[0].ports.first?.protocolName, .tcp)
        XCTAssertEqual(observed.services[0].ports.first?.bindAddress, "0.0.0.0")
        XCTAssertEqual(observed.services[0].resourceIdentifier, proofIdentity.managedResourceIdentifier)
        assertCompleteObservationMatrix(runner, expectedStatsContainerID: nil)
    }

    func testAppleContainerParserIncludesOwnedOrphanAndIgnoresUnrelatedProject() throws {
        let orphan = RuntimeServiceIdentity(projectName: "demo", serviceName: "orphan")
        let unrelated = RuntimeServiceIdentity(projectName: "other", serviceName: "api")
        let outputObject: [[String: Any]] = [
            realContainerListItem(
                identity: orphan,
                state: "running",
                networks: [[
                    "hostname": "orphan.local",
                    "ipv4Address": "192.168.64.2/24",
                    "ipv4Gateway": "192.168.64.1",
                    "ipv6Address": "fd00::2/64",
                    "macAddress": "02:00:00:00:00:02",
                    "mtu": 1280,
                    "network": "default"
                ]]
            ),
            realContainerListItem(identity: unrelated, state: "stopped", networks: [])
        ]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        let observed = try AppleContainerObservationParser.parse(
            output,
            desiredState: desiredState,
            metadata: ScriptedRuntimeAdapter.defaultMetadata
        )

        XCTAssertEqual(observed.services.map(\.identity), [orphan])
        XCTAssertEqual(observed.services[0].resourceIdentifier, orphan.managedResourceIdentifier)
        XCTAssertEqual(observed.services[0].networks[0].name, "default")
        XCTAssertEqual(observed.services[0].networks[0].hostname, "orphan.local")
        XCTAssertEqual(observed.services[0].networks[0].ipv4Address, "192.168.64.2/24")
        XCTAssertEqual(observed.services[0].networks[0].ipv4Gateway, "192.168.64.1")
        XCTAssertEqual(observed.services[0].networks[0].ipv6Address, "fd00::2/64")
        XCTAssertEqual(observed.services[0].networks[0].macAddress, "02:00:00:00:00:02")
        XCTAssertEqual(observed.services[0].networks[0].mtu, 1280)
    }

    func testAppleContainerParserRejectsDesiredVersionedContainerWithoutOwnershipLabels() throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": desiredService.image],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("missing exact ownership labels"))
        }
    }

    func testAppleContainerParserRejectsDesiredIdentifierClaimedByAnotherProject() throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let otherProjectIdentity = RuntimeServiceIdentity(projectName: "other", serviceName: identity.serviceName)
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": desiredService.image],
                "labels": RuntimeManagedResourceIdentity.labels(for: otherProjectIdentity),
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("claim another project"))
        }
    }

    func testAppleContainerParserUsesOwnershipVersionForLegacyIDMatchingV2Shape() throws {
        let serviceName = "0123456789abcdef0123456789abcdef"
        let legacyIdentity = RuntimeServiceIdentity(projectName: "v2-a-b", serviceName: serviceName)
        let legacyIdentifier = legacyIdentity.legacyManagedResourceIdentifier
        XCTAssertTrue(RuntimeManagedResourceIdentity.isCurrentIdentifier(legacyIdentifier))
        let state = DesiredRuntimeState(
            projectName: legacyIdentity.projectName,
            services: [DesiredRuntimeService(identity: legacyIdentity, image: "local/test:latest")],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: legacyIdentifier,
                    identity: legacyIdentity,
                    identityVersion: 1
                )
            ]
        )
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": legacyIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": legacyIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        let observed = try AppleContainerObservationParser.parse(
            output,
            desiredState: state,
            metadata: ScriptedRuntimeAdapter.defaultMetadata
        )

        XCTAssertEqual(observed.services.first?.identity, legacyIdentity)
        XCTAssertEqual(observed.services.first?.resourceIdentifier, legacyIdentifier)
    }

    func testAppleContainerParserRejectsUnlabeledVersionedOwnedOrphan() throws {
        let orphan = RuntimeServiceIdentity(projectName: "demo", serviceName: "orphan")
        let resourceIdentifier = orphan.managedResourceIdentifier
        let state = DesiredRuntimeState(
            projectName: "demo",
            services: [desiredService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: resourceIdentifier,
                    identity: orphan,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion
                )
            ]
        )
        let outputObject: [[String: Any]] = [[
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": [:],
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": "stopped", "networks": []]
        ]]
        let output = String(data: try JSONSerialization.data(withJSONObject: outputObject), encoding: .utf8)!

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: state,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("missing compatible exact ownership labels"))
        }
    }

    func testAppleContainerParserParsesRunningFixture() async throws {
        let runner = try appleContainerObservationRunner(
            containers: fixture("apple-container-1.1.0-inventory-containers.json")
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        let observed = try await adapter.observe(desiredState: desiredStateWithExactOwnership)

        XCTAssertEqual(observed.services.count, 1)
        XCTAssertEqual(observed.services[0].identity.serviceName, "api")
        XCTAssertEqual(observed.services[0].lifecycleState, .running)
        XCTAssertEqual(observed.services[0].healthState, .unknown)
        XCTAssertEqual(observed.services[0].ports.first?.hostPort, 8080)
        XCTAssertEqual(observed.services[0].ports.map(\.hostPort), [8080, 8081])
        XCTAssertEqual(observed.services[0].networks.first?.name, "default")
        XCTAssertEqual(observed.services[0].networks.first?.kind, "container-network-vmnet:nat")
        XCTAssertNil(observed.services[0].networks.first?.interfaceName)
        XCTAssertEqual(observed.services[0].mounts.map(\.target), ["/cache", "/srv/data"])
        XCTAssertEqual(observed.services[0].mounts.last?.access, .readOnly)
        assertCompleteObservationMatrix(
            runner,
            expectedStatsContainerID: identity.managedResourceIdentifier
        )
    }

    func testAppleContainerParserFailsClosedForMalformedRealNetworkOutput() {
        let resourceIdentifier = proofIdentity.managedResourceIdentifier
        let output = """
        [
          {
            "configuration": {
              "id": "\(resourceIdentifier)",
              "image": { "reference": "hostwright-proof-web:create-only" },
              "labels": {
                "dev.hostwright.managed": "true",
                "dev.hostwright.identity-version": "2",
                "dev.hostwright.project": "proof",
                "dev.hostwright.service": "web",
                "dev.hostwright.resource-id": "\(resourceIdentifier)"
              },
              "publishedPorts": []
            },
            "id": "\(resourceIdentifier)",
            "status": {
              "state": "running",
              "networks": [
                { "name": "vmnet" }
              ]
            }
          }
        ]
        """

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                output,
                desiredState: proofDesiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertTrue(message.contains("Unsupported Apple container network keys"))
        }
    }

    func testAppleContainerParserFailsClosedForMalformedOutputWithRedaction() {
        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                "not-json token=fake-token password=fake-password",
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("[REDACTED]"))
        }
    }

    func testAppleContainerParserFailsClosedForUnsupportedRealJSONShapesWithRedaction() {
        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                #"{"items":[],"token":"fake-token","password":"fake-password"}"#,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("Unsupported keys"))
        }

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                #"[{"id":"abc","image":"example","token":"fake-token"}]"#,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertTrue(message.contains("Unsupported real Apple container list item shape"))
        }
    }

    func testAppleContainerParserFailsClosedForRedactionFixture() throws {
        let redactionFixture = try fixture("apple-container-list-redaction.txt")

        XCTAssertThrowsError(
            try AppleContainerObservationParser.parse(
                redactionFixture,
                desiredState: desiredState,
                metadata: ScriptedRuntimeAdapter.defaultMetadata
            )
        ) { error in
            guard case RuntimeAdapterError.outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertFalse(message.contains("fake-token"))
            XCTAssertFalse(message.contains("fake-password"))
            XCTAssertTrue(message.contains("Unsupported keys"))
        }
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

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    }

    private var desiredState: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [
                desiredService
            ]
        )
    }

    private var desiredStateWithExactOwnership: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [desiredService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: identity.managedResourceIdentifier,
                    identity: identity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownershipEvidence(for: inventoryFixtureMutationContext)
                )
            ]
        )
    }

    private var desiredService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            command: ["serve"],
            environment: [RuntimeEnvironmentValue(name: "APP_ENV", value: "development")],
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )
    }

    private var mutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "operation-create-test",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    private var proofIdentity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "proof", serviceName: "web")
    }

    private var proofService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80)]
        )
    }

    private var proofDesiredState: DesiredRuntimeState {
        DesiredRuntimeState(projectName: "proof", services: [proofService])
    }

    private var proofDesiredStateWithExactOwnership: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "proof",
            services: [proofService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: proofIdentity.managedResourceIdentifier,
                    identity: proofIdentity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownershipEvidence(for: proofObservationMutationContext)
                )
            ]
        )
    }

    private var resolvedContainer: DictionaryRuntimeExecutableResolver {
        DictionaryRuntimeExecutableResolver(
            executables: [
                "container": "/usr/bin/container-fixture",
                "sw_vers": "/usr/bin/sw_vers-fixture",
                "uname": "/usr/bin/uname-fixture"
            ]
        )
    }

    private var inventoryFixtureMutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "inventory-fixture-observation",
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            resourceGeneration: 2,
            projectResourceUUID: "11111111-1111-4111-8111-111111111111",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    private var proofObservationMutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "b", count: 64),
            operationID: "proof-fixture-observation",
            resourceUUID: "44444444-4444-4444-8444-444444444444",
            resourceGeneration: 1,
            projectResourceUUID: "55555555-5555-4555-8555-555555555555",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "66666666-6666-4666-8666-666666666666"
        )
    }

    private func mutationConfirmation(
        planHash: String = "plan-hash",
        context: RuntimeMutationContext? = nil
    ) -> RuntimeMutationConfirmation {
        RuntimeMutationConfirmation(
            confirmed: true,
            reason: "test",
            planHash: planHash,
            context: context ?? RuntimeMutationContext(
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "a", count: 64),
                operationID: "runtime-test-operation",
                resourceUUID: HostwrightResourceUUID.generate(),
                resourceGeneration: 1,
                projectResourceUUID: HostwrightResourceUUID.generate(),
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: HostwrightResourceUUID.generate()
            )
        )
    }

    private func realContainerListItem(
        identity: RuntimeServiceIdentity,
        state: String,
        networks: [[String: Any]]
    ) -> [String: Any] {
        let resourceIdentifier = identity.managedResourceIdentifier
        return [
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": RuntimeManagedResourceIdentity.labels(for: identity),
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": state, "networks": networks]
        ]
    }

    private func containerListOutput(
        identity: RuntimeServiceIdentity,
        state: String,
        context: RuntimeMutationContext,
        startedDate: String? = nil
    ) throws -> String {
        let resourceIdentifier = identity.managedResourceIdentifier
        var container = try structuredInventoryTemplate()[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])

        container["id"] = resourceIdentifier
        configuration["id"] = resourceIdentifier
        configuration["labels"] = try RuntimeManagedResourceIdentity.labels(
            for: identity,
            context: context
        )
        configuration["mounts"] = []
        configuration["networks"] = []
        configuration["publishedPorts"] = []
        image["reference"] = "local/test:latest"
        configuration["image"] = image
        status["networks"] = []
        status["state"] = state
        status["startedDate"] = startedDate
        container["configuration"] = configuration
        container["status"] = status

        return String(
            decoding: try JSONSerialization.data(withJSONObject: [container], options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func ownershipEvidence(
        for context: RuntimeMutationContext
    ) -> RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            resourceGeneration: context.resourceGeneration,
            projectGeneration: context.projectGeneration,
            providerID: context.providerID,
            providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken
        )
    }

    private func appleContainerObservationRunner(
        containers: String
    ) throws -> AppleObservationRuntimeProcessRunner {
        AppleObservationRuntimeProcessRunner(
            version: try fixture("apple-container-1.1.0-version.txt"),
            status: try fixture("apple-container-1.1.0-system-status.json"),
            containers: containers,
            images: try fixture("apple-container-1.1.0-image-list.json"),
            networks: try fixture("apple-container-1.1.0-network-list.json"),
            volumes: try fixture("apple-container-1.1.0-volume-list.json"),
            machines: try fixture("apple-container-1.1.0-machine-list.json"),
            statsByContainerID: [
                identity.managedResourceIdentifier: try fixture("apple-container-1.1.0-stats.json")
            ]
        )
    }

    private func structuredBuilderContainerOutput() throws -> String {
        var payload = try structuredInventoryTemplate()
        var container = payload[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])

        container["id"] = "buildkit"
        configuration["id"] = "buildkit"
        configuration["labels"] = [
            "com.apple.container.plugin": "builder",
            "com.apple.container.resource.role": "builder"
        ]
        image["reference"] = "ghcr.io/apple/container-builder-shim/builder:0.12.0"
        configuration["image"] = image
        status["state"] = "running"
        container["configuration"] = configuration
        container["status"] = status
        payload = [container]

        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func structuredProofContainerOutput() throws -> String {
        var payload = try structuredInventoryTemplate()
        var container = payload[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])
        let resourceIdentifier = proofIdentity.managedResourceIdentifier

        container["id"] = resourceIdentifier
        configuration["id"] = resourceIdentifier
        configuration["labels"] = try RuntimeManagedResourceIdentity.labels(
            for: proofIdentity,
            context: proofObservationMutationContext
        )
        configuration["networks"] = []
        configuration["publishedPorts"] = [[
            "containerPort": 80,
            "count": 1,
            "hostAddress": "0.0.0.0",
            "hostPort": 18080,
            "proto": "tcp"
        ]]
        image["reference"] = "hostwright-proof-web:create-only"
        configuration["image"] = image
        status["networks"] = []
        status["state"] = "stopped"
        container["configuration"] = configuration
        container["status"] = status
        payload = [container]

        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    private func structuredInventoryTemplate() throws -> [[String: Any]] {
        let data = Data(try fixture("apple-container-1.1.0-inventory-containers.json").utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
    }

    private func assertCompleteObservationMatrix(
        _ runner: AppleObservationRuntimeProcessRunner,
        expectedStatsContainerID: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expected = [
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/sw_vers-fixture -productVersion",
            "/usr/bin/sw_vers-fixture -buildVersion",
            "/usr/bin/uname-fixture -m",
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/container-fixture list --all --format json",
            "/usr/bin/container-fixture image list --format json",
            "/usr/bin/container-fixture network list --format json",
            "/usr/bin/container-fixture volume list --format json",
            "/usr/bin/container-fixture machine list --format json"
        ]
        if let expectedStatsContainerID {
            expected.append(
                "/usr/bin/container-fixture stats \(expectedStatsContainerID) --no-stream --format json"
            )
        }
        expected += [
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/sw_vers-fixture -productVersion",
            "/usr/bin/sw_vers-fixture -buildVersion",
            "/usr/bin/uname-fixture -m"
        ]

        XCTAssertEqual(
            runner.calls.map { "\($0.executablePath) \($0.arguments.joined(separator: " "))" },
            expected,
            file: file,
            line: line
        )
        XCTAssertTrue(
            runner.calls.allSatisfy { $0.classification == .readOnly },
            file: file,
            line: line
        )
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func processSpec(
        executablePath: String,
        arguments: [String],
        timeout: Int = 5
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executablePath,
            arguments: arguments,
            timeout: RuntimeCommandTimeout(seconds: timeout),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "secure process integration"
        )
    }

    private final class AppleObservationRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
        private let version: String
        private let status: String
        private let containers: String
        private let images: String
        private let networks: String
        private let volumes: String
        private let machines: String
        private let statsByContainerID: [String: String]
        private(set) var calls: [RuntimeCommandSpec] = []

        init(
            version: String,
            status: String,
            containers: String,
            images: String,
            networks: String,
            volumes: String,
            machines: String,
            statsByContainerID: [String: String]
        ) {
            self.version = version
            self.status = status
            self.containers = containers
            self.images = images
            self.networks = networks
            self.volumes = volumes
            self.machines = machines
            self.statsByContainerID = statsByContainerID
        }

        func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
            try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
            calls.append(spec)

            let output: String
            switch (spec.executablePath, spec.arguments) {
            case ("/usr/bin/container-fixture", ["--version"]):
                output = version
            case ("/usr/bin/container-fixture", ["system", "status", "--format", "json"]):
                output = status
            case ("/usr/bin/container-fixture", ["list", "--all", "--format", "json"]):
                output = containers
            case ("/usr/bin/container-fixture", ["image", "list", "--format", "json"]):
                output = images
            case ("/usr/bin/container-fixture", ["network", "list", "--format", "json"]):
                output = networks
            case ("/usr/bin/container-fixture", ["volume", "list", "--format", "json"]):
                output = volumes
            case ("/usr/bin/container-fixture", ["machine", "list", "--format", "json"]):
                output = machines
            case ("/usr/bin/sw_vers-fixture", ["-productVersion"]):
                output = "26.0\n"
            case ("/usr/bin/sw_vers-fixture", ["-buildVersion"]):
                output = "25A1\n"
            case ("/usr/bin/uname-fixture", ["-m"]):
                output = "arm64\n"
            default:
                if spec.executablePath == "/usr/bin/container-fixture",
                   spec.arguments.count == 5,
                   spec.arguments.first == "stats",
                   Array(spec.arguments.dropFirst(2)) == ["--no-stream", "--format", "json"],
                   let containerID = spec.arguments.dropFirst().first,
                   let stats = statsByContainerID[containerID] {
                    output = stats
                } else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Unexpected Apple observation command."
                    )
                }
            }

            return RuntimeCommandResult(
                spec: spec,
                exitStatus: 0,
                standardOutput: output,
                standardError: ""
            )
        }
    }

    private final class RoutingRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
        typealias Handler = @Sendable (RuntimeCommandSpec) throws -> RuntimeCommandResult

        private let handler: Handler
        private(set) var calls: [RuntimeCommandSpec] = []

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
            if spec.arguments == ["--version"] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: "container CLI version 1.1.0 (build: release, commit: 5973b9c)\n",
                    standardError: ""
                )
            }
            switch spec.classification {
            case .readOnly:
                try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
            case .mutating:
                try RuntimeCommandPolicy.validateSupportedMutation(spec)
            case .forbidden, .unknown:
                throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "rejected")
            }

            do {
                let result = try handler(spec)
                calls.append(spec)
                return result
            } catch let error as RuntimeAdapterError {
                if case .commandRejected = error,
                   let output = structuredObservationFallback(for: spec) {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: output,
                        standardError: ""
                    )
                }
                calls.append(spec)
                throw error
            }
        }

        private func structuredObservationFallback(for spec: RuntimeCommandSpec) -> String? {
            switch (spec.executablePath, spec.arguments) {
            case ("/usr/bin/container-fixture", ["system", "status", "--format", "json"]):
                return #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","apiServerBuild":"release","apiServerCommit":"5973b9c","apiServerAppName":"container-apiserver"}"#
            case ("/usr/bin/sw_vers-fixture", ["-productVersion"]):
                return "26.0\n"
            case ("/usr/bin/sw_vers-fixture", ["-buildVersion"]):
                return "25A1\n"
            case ("/usr/bin/uname-fixture", ["-m"]):
                return "arm64\n"
            case ("/usr/bin/container-fixture", ["image", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["network", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["volume", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["machine", "list", "--format", "json"]):
                if spec.arguments.first == "image" {
                    return #"[{"id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","configuration":{"name":"local/test:latest","descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},"variants":[]}]"#
                }
                return "[]"
            default:
                if spec.executablePath == "/usr/bin/container-fixture",
                   spec.arguments.count == 5,
                   spec.arguments.first == "stats" {
                    let id = spec.arguments[1]
                    return #"[{"id":"\#(id)","cpuUsageUsec":1,"memoryUsageBytes":2,"memoryLimitBytes":3,"networkRxBytes":4,"networkTxBytes":5,"blockReadBytes":6,"blockWriteBytes":7,"numProcesses":1}]"#
                }
                return nil
            }
        }
    }

    private final class ObservationFixtureSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [String]

        init(outputs: [String]) {
            self.outputs = outputs
        }

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return outputs.isEmpty ? "[]" : outputs.removeFirst()
        }
    }

    private final class RecordingRuntimeHealthURLFetcher: RuntimeHealthURLFetching, @unchecked Sendable {
        struct Request: Equatable {
            let url: URL
            let timeout: RuntimeCommandTimeout
        }

        private let response: RuntimeHealthURLResponse?
        private let error: Error?
        private(set) var requests: [Request] = []

        init(response: RuntimeHealthURLResponse? = nil, error: Error? = nil) {
            self.response = response
            self.error = error
        }

        func fetch(url: URL, timeout: RuntimeCommandTimeout) async throws -> RuntimeHealthURLResponse {
            requests.append(Request(url: url, timeout: timeout))
            if let error {
                throw error
            }
            return response ?? RuntimeHealthURLResponse(statusCode: 200)
        }
    }
}

private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.hostwright.tests.loopback-http")
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let response: Data
    private var startupError: String?
    private var requests = 0

    init(statusCode: Int, body: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        response = Data(
            "HTTP/1.1 \(statusCode) Test\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
        )

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                lock.lock()
                startupError = String(describing: error)
                lock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(
                domain: "HostwrightRuntimeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server did not become ready."]
            )
        }
        if let startupError {
            listener.cancel()
            throw NSError(
                domain: "HostwrightRuntimeTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: startupError]
            )
        }
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] _, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            lock.lock()
            requests += 1
            lock.unlock()
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
