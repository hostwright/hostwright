import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightRuntime
@testable import HostwrightSecrets

extension HostwrightRuntimeTests {
    func testAppleActivationAuthorityExpiresDuringImageAndCodecPreparation() async throws {
        for kind: PlannedRuntimeActionKind in [.create, .start] {
            let imageList = try fixture("apple-container-image-list-real-json.txt")
            let runner = RoutingRuntimeProcessRunner { spec in
                if spec.arguments == ["image", "list", "--format", "json"] {
                    return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: imageList, standardError: "")
                }
                throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
            }
            let gate = ActivationAuthorityTestGate()
            let adapter = AppleContainerApplyAdapter(
                executableResolver: resolvedContainer,
                processRunner: DelayedActivationRuntimeRunner(base: runner, gate: gate) { spec in
                    kind == .create ? spec.arguments.first == "image" : spec.arguments == ["--version"]
                }
            )
            do {
                _ = try await RuntimeActivationAuthority.$validator.withValue({ try gate.validate() }) {
                    try RuntimeActivationAuthority.validate()
                    return try await adapter.execute(
                        PlannedRuntimeAction(
                            kind: kind, identity: proofIdentity,
                            resourceIdentifier: proofIdentity.managedResourceIdentifier,
                            isDestructive: false, summary: kind.rawValue, desiredService: proofService
                        ),
                        confirmation: mutationConfirmation(context: proofObservationMutationContext)
                    )
                }
                XCTFail("Expired provider authority must reject \(kind).")
            } catch let error as RuntimeActivationAuthorityRejection {
                XCTAssertTrue(error.diagnostic.contains("Admission expired"))
            }
            XCTAssertTrue(runner.calls.filter { $0.classification == .mutating }.isEmpty)
            XCTAssertNoThrow(try RuntimeActivationAuthority.validate())
        }
    }

    func testAppleRestartAuthorityExpiringAfterStopPreservesPartialEffect() async throws {
        let resourceIdentifier = identity.managedResourceIdentifier
        let observations = ObservationFixtureSequence(outputs: [
            try containerListOutput(identity: identity, state: "running", context: mutationContext),
            try containerListOutput(identity: identity, state: "stopped", context: mutationContext)
        ])
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["stop", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "stopped", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: observations.next(), standardError: "")
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let gate = ActivationAuthorityTestGate()
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: DelayedActivationRuntimeRunner(base: runner, gate: gate) { $0.arguments.first == "stop" }
        )
        do {
            _ = try await RuntimeActivationAuthority.$validator.withValue({ try gate.validate() }) {
                try await adapter.execute(
                    PlannedRuntimeAction(
                        kind: .restart, identity: identity, resourceIdentifier: resourceIdentifier,
                        isDestructive: true, summary: "restart"
                    ),
                    confirmation: mutationConfirmation(context: mutationContext)
                )
            }
            XCTFail("Restart must fail after authority expires during stop verification.")
        } catch let error as RuntimeAdapterError {
            guard case .managedRestartStartFailedAfterStop = error else {
                return XCTFail("The completed stop must remain a partial effect: \(error).")
            }
        }
        XCTAssertEqual(runner.calls.filter { $0.classification == .mutating }.map(\.arguments), [["stop", resourceIdentifier]])
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

    func testAppleContainerApplyAdapterCreatesFromExactLockedDigest() async throws {
        let imageFixture = try fixture(
            "apple-container-1.1.0-image-list.json"
        )
        let createdFixture = try containerListOutput(
            identity: proofIdentity,
            state: "stopped",
            context: proofObservationMutationContext
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            switch spec.arguments {
            case ["image", "list", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: imageFixture,
                    standardError: ""
                )
            case ["list", "--all", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: createdFixture,
                    standardError: ""
                )
            default:
                if spec.arguments.first == "create" {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: "created",
                        standardError: ""
                    )
                }
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected command"
                )
            }
        }
        let descriptor =
            "sha256:\(String(repeating: "c", count: 64))"
        let resolved = "ghcr.io/example/api@\(descriptor)"
        let lock = try RuntimeImageDigestLock(
            requestedReference: "ghcr.io/example/api:1.1.0",
            resolvedReference: resolved,
            descriptorDigest: descriptor,
            variantDigest:
                "sha256:\(String(repeating: "d", count: 64))",
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256:
                proofObservationMutationContext.capabilitySHA256
        )
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: resolved,
            imageLock: lock,
            ports: [
                RuntimePortMapping(
                    hostPort: 18080,
                    containerPort: 80
                )
            ]
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        _ = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .create,
                identity: proofIdentity,
                resourceIdentifier:
                    proofIdentity.managedResourceIdentifier,
                isDestructive: false,
                summary: "create exact digest",
                desiredService: service
            ),
            confirmation: mutationConfirmation(
                context: proofObservationMutationContext
            )
        )

        let create = try XCTUnwrap(
            runner.calls.first { $0.arguments.first == "create" }
        )
        XCTAssertTrue(create.arguments.contains(resolved))
        XCTAssertFalse(
            create.arguments.contains("ghcr.io/example/api:1.1.0")
        )
    }

    func testAppleContainerApplyAdapterRejectsLockedContentDriftBeforeMutation() async throws {
        let imageFixture = try fixture(
            "apple-container-1.1.0-image-list.json"
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments ==
                ["image", "list", "--format", "json"] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: imageFixture,
                    standardError: ""
                )
            }
            XCTFail("Content drift must fail before native mutation.")
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "must not mutate"
            )
        }
        let descriptor =
            "sha256:\(String(repeating: "c", count: 64))"
        let resolved = "ghcr.io/example/api@\(descriptor)"
        let lock = try RuntimeImageDigestLock(
            requestedReference: "ghcr.io/example/api:1.1.0",
            resolvedReference: resolved,
            descriptorDigest: descriptor,
            variantDigest:
                "sha256:\(String(repeating: "e", count: 64))",
            operatingSystem: "linux",
            architecture: "arm64",
            providerID: .appleContainerCLI,
            capabilitySHA256:
                proofObservationMutationContext.capabilitySHA256
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: proofIdentity,
                    resourceIdentifier:
                        proofIdentity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "reject drift",
                    desiredService: DesiredRuntimeService(
                        identity: proofIdentity,
                        image: resolved,
                        imageLock: lock
                    )
                ),
                confirmation: mutationConfirmation(
                    context: proofObservationMutationContext
                )
            )
            XCTFail("Expected locked content drift rejection.")
        } catch {
            guard case RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: let message
            ) = error else {
                return XCTFail("Expected mutating rejection, got \(error).")
            }
            XCTAssertTrue(message.contains("no longer matches"))
        }
        XCTAssertEqual(runner.calls.count, 1)
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
        let observations = ObservationFixtureSequence(outputs: [
            try containerListOutput(
                identity: identity,
                state: "running",
                context: mutationContext
            ),
            "[]"
        ])
        let runner = RoutingRuntimeProcessRunner { spec in
            if spec.arguments == ["delete", resourceIdentifier] {
                return RuntimeCommandResult(spec: spec, exitStatus: 0, standardOutput: "deleted", standardError: "")
            }
            if spec.arguments == ["list", "--all", "--format", "json"] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: observations.next(),
                    standardError: ""
                )
            }
            throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "unexpected command")
        }
        let adapter = AppleContainerApplyAdapter(executableResolver: resolvedContainer, processRunner: runner)

        let event = try await adapter.execute(
            PlannedRuntimeAction(kind: .remove, identity: identity, resourceIdentifier: resourceIdentifier, isDestructive: true, summary: "delete"),
            confirmation: mutationConfirmation(planHash: "cleanup-token", context: mutationContext)
        )

        XCTAssertEqual(event.resourceIdentifier, resourceIdentifier)
        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [
                ["list", "--all", "--format", "json"],
                ["delete", resourceIdentifier],
                ["list", "--all", "--format", "json"]
            ]
        )

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

    func testAppleContainerApplyAdapterRejectsUnsafeBindBeforeAnyRuntimeInvocation() async throws {
        let runner = RoutingRuntimeProcessRunner { spec in
            XCTFail("Unsafe bind path must fail before runtime access: \(spec.arguments)")
            return RuntimeCommandResult(spec: spec, exitStatus: 1, standardOutput: "", standardError: "")
        }
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            mounts: [
                RuntimeMountReference(
                    source: "/tmp/../etc",
                    target: "/data",
                    kind: .bind,
                    access: .readOnly
                )
            ]
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: identity,
                    resourceIdentifier: identity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "create",
                    desiredService: service
                ),
                confirmation: mutationConfirmation()
            )
            XCTFail("Expected unsafe bind path rejection.")
        } catch let error as GuardedMountSecurityError {
            XCTAssertEqual(error, .parentTraversalForbidden)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAppleContainerApplyAdapterVerifiesExactBindMountAfterCreate() async throws {
        let rawTemporaryPath =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            rawTemporaryPath.hasPrefix("/var/")
                ? "/private\(rawTemporaryPath)"
                : rawTemporaryPath
        let bindSource = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        )
            .appendingPathComponent("hostwright-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bindSource,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: bindSource))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bindSource.path))
        }

        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let imageObservations = ObservationFixtureSequence(
            outputs: [
                imageListFixture,
                try fixture(
                    "apple-container-1.1.0-image-list.json"
                ),
            ]
        )
        let createdFixture = try containerListOutput(
            identity: proofIdentity,
            state: "stopped",
            context: proofObservationMutationContext,
            mounts: [[
                "destination": "/data",
                "options": ["ro"],
                "source": bindSource.path,
                "type": ["virtiofs": [:]]
            ]]
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            switch spec.arguments {
            case ["image", "list", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: imageObservations.next(),
                    standardError: ""
                )
            case ["list", "--all", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: createdFixture,
                    standardError: ""
                )
            default:
                if spec.arguments.first == "create" {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: "created",
                        standardError: ""
                    )
                }
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected command"
                )
            }
        }
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: proofService.image,
            mounts: [
                RuntimeMountReference(
                    source: bindSource.path,
                    target: "/data",
                    kind: .bind,
                    access: .readOnly
                )
            ]
        )
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
                summary: "create with exact bind",
                desiredService: service
            ),
            confirmation: mutationConfirmation(
                context: proofObservationMutationContext
            )
        )

        XCTAssertEqual(
            event.resourceIdentifier,
            proofIdentity.managedResourceIdentifier
        )
        XCTAssertEqual(
            runner.calls.filter { $0.arguments.first == "create" }.count,
            1
        )
    }

    func testAppleContainerApplyAdapterRejectsObservedBindMountMismatchAfterCreate() async throws {
        let rawTemporaryPath =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath =
            rawTemporaryPath.hasPrefix("/var/")
                ? "/private\(rawTemporaryPath)"
                : rawTemporaryPath
        let bindSource = URL(
            fileURLWithPath: canonicalTemporaryPath,
            isDirectory: true
        )
            .appendingPathComponent("hostwright-bind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bindSource,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: bindSource))
            XCTAssertFalse(FileManager.default.fileExists(atPath: bindSource.path))
        }

        let imageListFixture = try fixture("apple-container-image-list-real-json.txt")
        let imageObservations = ObservationFixtureSequence(
            outputs: [
                imageListFixture,
                try fixture(
                    "apple-container-1.1.0-image-list.json"
                ),
            ]
        )
        let createdFixture = try containerListOutput(
            identity: proofIdentity,
            state: "stopped",
            context: proofObservationMutationContext,
            mounts: [[
                "destination": "/data",
                "options": [],
                "source": bindSource.path,
                "type": ["virtiofs": [:]]
            ]]
        )
        let runner = RoutingRuntimeProcessRunner { spec in
            switch spec.arguments {
            case ["image", "list", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: imageObservations.next(),
                    standardError: ""
                )
            case ["list", "--all", "--format", "json"]:
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: createdFixture,
                    standardError: ""
                )
            default:
                if spec.arguments.first == "create" {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: "created",
                        standardError: ""
                    )
                }
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected command"
                )
            }
        }
        let service = DesiredRuntimeService(
            identity: proofIdentity,
            image: proofService.image,
            mounts: [
                RuntimeMountReference(
                    source: bindSource.path,
                    target: "/data",
                    kind: .bind,
                    access: .readOnly
                )
            ]
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: resolvedContainer,
            processRunner: runner
        )

        do {
            _ = try await adapter.execute(
                PlannedRuntimeAction(
                    kind: .create,
                    identity: proofIdentity,
                    resourceIdentifier: proofIdentity.managedResourceIdentifier,
                    isDestructive: false,
                    summary: "reject observed bind mismatch",
                    desiredService: service
                ),
                confirmation: mutationConfirmation(
                    context: proofObservationMutationContext
                )
            )
            XCTFail("Expected exact observed bind-mount mismatch rejection.")
        } catch let error as RuntimeAdapterError {
            guard case .outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertTrue(message.contains("exact guarded bind-mount"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

        XCTAssertEqual(
            runner.calls.filter { $0.arguments.first == "create" }.count,
            1
        )
    }
}
