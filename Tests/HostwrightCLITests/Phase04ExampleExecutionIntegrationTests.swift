import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class Phase04ExampleExecutionIntegrationTests: XCTestCase {
    func testCheckedInLifecycleExamplesExecuteThroughProductionRunner() throws {
        try withTemporaryRoot { temporaryRoot in
            let single = try example("single-service/hostwright.yaml")
            try runLifecyclePair(.up, example: single, temporaryRoot: temporaryRoot)
            try runLifecyclePair(
                .stop,
                example: single,
                observedLifecycle: .running,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .start,
                example: single,
                observedLifecycle: .stopped,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .restart,
                example: single,
                observedLifecycle: .running,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .run,
                example: single,
                serviceNames: ["web"],
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .down,
                example: single,
                observedLifecycle: .running,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .rm,
                example: single,
                observedLifecycle: .running,
                temporaryRoot: temporaryRoot
            )

            let application = try example("app-suite/hostwright.yaml")
            try runLifecyclePair(
                .up,
                example: application,
                output: .json,
                parallelism: 4,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .update,
                example: application,
                previous: application,
                observedLifecycle: .running,
                output: .json,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .down,
                example: application,
                observedLifecycle: .running,
                output: .json,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .rm,
                example: application,
                observedLifecycle: .running,
                output: .json,
                temporaryRoot: temporaryRoot
            )

            let healthy = try example("unhealthy-rollback/hostwright.yaml")
            let unhealthy = try example("unhealthy-rollback/unhealthy.yaml")
            try runLifecyclePair(
                .up,
                example: healthy,
                output: .json,
                temporaryRoot: temporaryRoot
            )
            let failedUpdate = try runLifecyclePair(
                .update,
                example: unhealthy,
                previous: healthy,
                observedLifecycle: .running,
                output: .json,
                executionStatus: .compensated,
                temporaryRoot: temporaryRoot
            )
            XCTAssertEqual(
                failedUpdate.execution.exitCode,
                CLIExitCode.partialFailure.rawValue
            )
            XCTAssertTrue(
                failedUpdate.execution.standardError.contains("\"status\":\"compensated\"")
            )
            try assertRecoveryExample(
                projectName: healthy.manifest.project!,
                plan: failedUpdate.plan,
                temporaryRoot: temporaryRoot
            )
            let recoveryInspectDriver = ExampleInteractiveDriver(
                projectName: healthy.manifest.project!
            )
            let recoveryInspect = InteractiveCommandRunner(
                options: try interactiveOptions([
                    "inspect", "web", "--manifest", healthy.path,
                    "--output", "json"
                ]),
                driver: recoveryInspectDriver
            ).run()
            XCTAssertEqual(
                recoveryInspect.exitCode,
                0,
                recoveryInspect.standardError
            )
            XCTAssertEqual(recoveryInspectDriver.snapshot(), [.inspect])

            let automation = try example("api-redis/hostwright.yaml")
            try runLifecyclePair(
                .up,
                example: automation,
                output: .json,
                temporaryRoot: temporaryRoot
            )
            try runLifecyclePair(
                .rm,
                example: automation,
                observedLifecycle: .running,
                output: .json,
                temporaryRoot: temporaryRoot
            )
        }
    }

    func testCheckedInInteractiveExamplesExecuteThroughProductionRunner() throws {
        try withTemporaryRoot { temporaryRoot in
            let automation = try example("api-redis/hostwright.yaml")
            let inputPath = temporaryRoot.appendingPathComponent("input.txt").path
            try Data("example-input".utf8).write(to: URL(fileURLWithPath: inputPath))
            let exportPath = temporaryRoot.appendingPathComponent("hostwright-api.tar").path
            let driver = ExampleInteractiveDriver(
                projectName: automation.manifest.project!
            )
            let commandArguments = [
                [
                    "inspect", "api", "--manifest", automation.path,
                    "--output", "json"
                ],
                [
                    "stats", "api", "--manifest", automation.path,
                    "--output", "json"
                ],
                [
                    "exec", "api", "--manifest", automation.path,
                    "--output", "json", "--", "python3", "-c", "print('ok')"
                ],
                [
                    "copy", inputPath, "api:/tmp/input.txt",
                    "--manifest", automation.path, "--output", "json"
                ],
                [
                    "export", "api", exportPath,
                    "--manifest", automation.path, "--output", "json"
                ],
                [
                    "logs", "api", automation.path, "--follow", "--tail", "20",
                    "--output", "json"
                ],
                [
                    "exec", "api", "--manifest", automation.path,
                    "--tty", "--", "python3"
                ],
                [
                    "attach", "api", "--manifest", automation.path
                ]
            ]

            for arguments in commandArguments {
                let options = try interactiveOptions(arguments)
                let result = InteractiveCommandRunner(
                    options: options,
                    driver: driver
                ).run()
                XCTAssertEqual(result.exitCode, 0, "\(arguments): \(result.standardError)")
                XCTAssertFalse(result.standardOutput.isEmpty, "\(arguments)")
                XCTAssertTrue(result.standardError.isEmpty, "\(arguments)")
            }

            XCTAssertEqual(
                driver.snapshot(),
                [
                    .inspect,
                    .stats,
                    .exec,
                    .copyIn,
                    .export,
                    .logsFollow,
                    .exec,
                    .attach
                ]
            )
        }
    }

    func testCheckedInExpectedFailuresStopBeforeExecution() throws {
        try withTemporaryRoot { temporaryRoot in
            let namedVolume = try example("expected-failures/named-volume.yaml")
            let preparation = try lifecyclePreparation(
                example: namedVolume,
                previous: nil,
                observedLifecycle: nil
            )
            let namedVolumeDriver = ExampleLifecycleDriver(
                preparation: preparation
            )
            let namedVolumeResult = LifecycleCommandRunner(
                options: try lifecycleOptions(
                    command: .up,
                    manifestPath: namedVolume.path,
                    dryRun: true,
                    confirmation: nil,
                    serviceNames: [],
                    output: .json,
                    parallelism: nil
                ),
                driver: namedVolumeDriver
            ).run()

            XCTAssertEqual(
                namedVolumeResult.exitCode,
                CLIExitCode.validation.rawValue
            )
            XCTAssertTrue(namedVolumeResult.standardError.contains("Phase 06"))
            XCTAssertEqual(namedVolumeDriver.executionCount, 0)

            let secret = try example("expected-failures/unavailable-secret.yaml")
            XCTAssertTrue(
                secret.mapping.desiredState.services.contains {
                    $0.environment.contains { $0.secretReference != nil }
                }
            )
            let secretDriver = ExampleLifecycleDriver(
                preparation: try lifecyclePreparation(
                    example: secret,
                    previous: nil,
                    observedLifecycle: nil
                ),
                secretBackendUnavailable: true
            )
            let secretDatabasePath = temporaryRoot
                .appendingPathComponent("expected-failures-secret.sqlite").path
            let secretResult = LifecycleCommandRunner(
                options: try lifecycleOptions(
                    command: .up,
                    manifestPath: secret.path,
                    dryRun: true,
                    confirmation: nil,
                    serviceNames: [],
                    output: .json,
                    parallelism: nil,
                    stateDatabasePath: secretDatabasePath
                ),
                driver: secretDriver
            ).run()

            XCTAssertEqual(secretResult.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertTrue(secretResult.standardError.contains("secret backend"))
            XCTAssertEqual(secretDriver.executionCount, 0)

            let confirmedSecretResult = LifecycleCommandRunner(
                options: try lifecycleOptions(
                    command: .up,
                    manifestPath: secret.path,
                    dryRun: false,
                    confirmation: String(repeating: "f", count: 64),
                    serviceNames: [],
                    output: .json,
                    parallelism: nil,
                    stateDatabasePath: secretDatabasePath
                ),
                driver: secretDriver
            ).run()

            XCTAssertEqual(
                confirmedSecretResult.exitCode,
                CLIExitCode.validation.rawValue
            )
            XCTAssertTrue(
                confirmedSecretResult.standardError.contains("secret backend")
            )
            XCTAssertEqual(secretDriver.executionCount, 0)
            XCTAssertEqual(secretDriver.revalidationCount, 0)
            XCTAssertEqual(secretDriver.imageCheckCount, 0)
            let store = SQLiteStateStore(path: secretDatabasePath)
            try store.migrate()
            XCTAssertTrue(try store.operations.loadAll().isEmpty)
            XCTAssertTrue(try store.operationGroups.loadAll().isEmpty)
            XCTAssertTrue(try store.events.loadAll().isEmpty)
            XCTAssertTrue(try store.ownership.loadAll().isEmpty)

            let unsupportedNetworkPath = examplesRoot
                .appendingPathComponent("expected-failures/unsupported-network.yaml")
            let unsupportedNetwork = try String(
                contentsOf: unsupportedNetworkPath,
                encoding: .utf8
            )
            XCTAssertThrowsError(try ManifestValidator.validated(unsupportedNetwork)) {
                XCTAssertTrue(String(describing: $0).contains("networks"))
            }
        }
    }

    @discardableResult
    private func runLifecyclePair(
        _ command: LifecycleCommandKind,
        example: Example,
        previous: Example? = nil,
        observedLifecycle: RuntimeLifecycleState? = nil,
        serviceNames: [String] = [],
        output: CLIOutputFormat = .text,
        parallelism: Int? = nil,
        executionStatus: LifecycleSagaExecutionStatus = .succeeded,
        temporaryRoot: URL
    ) throws -> (plan: LifecyclePlan, execution: CLIRunResult) {
        let preparation = try lifecyclePreparation(
            example: example,
            previous: previous,
            observedLifecycle: observedLifecycle
        )
        let driver = ExampleLifecycleDriver(
            preparation: preparation,
            executionStatus: executionStatus
        )
        let dryOptions = try lifecycleOptions(
            command: command,
            manifestPath: example.path,
            dryRun: true,
            confirmation: nil,
            serviceNames: serviceNames,
            output: output,
            parallelism: parallelism
        )
        let dryRun = LifecycleCommandRunner(
            options: dryOptions,
            driver: driver
        ).run()
        XCTAssertEqual(dryRun.exitCode, 0, dryRun.standardError)
        let plan = try LifecycleCommandPlanCompiler().compile(
            options: dryOptions,
            preparation: preparation
        ).plan
        if output == .json {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    LifecyclePlan.self,
                    from: Data(dryRun.standardOutput.utf8)
                ),
                plan
            )
        } else {
            XCTAssertTrue(
                dryRun.standardOutput.hasPrefix(
                    "Lifecycle plan \(plan.planSHA256)\n"
                )
            )
        }

        let confirmedOptions = try lifecycleOptions(
            command: command,
            manifestPath: example.path,
            dryRun: false,
            confirmation: plan.planSHA256,
            serviceNames: serviceNames,
            output: output,
            parallelism: parallelism
        )
        let execution = LifecycleCommandRunner(
            options: confirmedOptions,
            driver: driver
        ).run()
        if executionStatus == .succeeded {
            XCTAssertEqual(execution.exitCode, 0, execution.standardError)
            XCTAssertFalse(execution.standardOutput.isEmpty)
        }
        XCTAssertEqual(driver.executionCount, 1)
        XCTAssertEqual(driver.revalidationCount, 1)
        XCTAssertEqual(
            driver.imageCheckCount,
            plan.nodes.contains { $0.action == .create } ? 2 : 0
        )
        XCTAssertTrue(
            temporaryRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        )
        return (plan, execution)
    }

    private func lifecycleOptions(
        command: LifecycleCommandKind,
        manifestPath: String,
        dryRun: Bool,
        confirmation: String?,
        serviceNames: [String],
        output: CLIOutputFormat,
        parallelism: Int?,
        stateDatabasePath: String? = nil
    ) throws -> LifecycleCLIOptions {
        var arguments = [command.rawValue, manifestPath]
        for serviceName in serviceNames {
            arguments.append(contentsOf: ["--service", serviceName])
        }
        if let stateDatabasePath {
            arguments.append(contentsOf: ["--state-db", stateDatabasePath])
        }
        if dryRun {
            arguments.append("--dry-run")
        } else {
            arguments.append(contentsOf: ["--confirm-plan", confirmation!])
        }
        if let parallelism {
            arguments.append(contentsOf: ["--parallelism", String(parallelism)])
        }
        if output == .json {
            arguments.append(contentsOf: ["--output", "json"])
        }
        guard case .lifecycle(let options) = try CLICommand.parse(arguments: arguments) else {
            throw ExampleHarnessError.unexpectedCommand
        }
        return options
    }

    private func interactiveOptions(
        _ arguments: [String]
    ) throws -> InteractiveCLIOptions {
        guard case .interactive(let options) = try CLICommand.parse(arguments: arguments) else {
            throw ExampleHarnessError.unexpectedCommand
        }
        return options
    }

    private func lifecyclePreparation(
        example: Example,
        previous: Example?,
        observedLifecycle: RuntimeLifecycleState?
    ) throws -> LifecycleCommandPreparation {
        let projectName = example.mapping.desiredState.projectName
        let observedServices = observedLifecycle.map { lifecycle in
            (previous?.mapping.desiredState.services ??
                example.mapping.desiredState.services).map { desired in
                ObservedRuntimeService(
                    identity: desired.identity,
                    resourceIdentifier: desired.identity.managedResourceIdentifier,
                    image: desired.image,
                    lifecycleState: lifecycle,
                    healthState: lifecycle == .running ? .healthy : .notConfigured,
                    ports: desired.ports,
                    mounts: desired.mounts
                )
            }
        } ?? []
        let bindings = try observedServices.map {
            try lifecycleBinding(
                observed: $0,
                projectName: projectName
            )
        }
        let capabilitySHA256 = String(repeating: "c", count: 64)
        return LifecycleCommandPreparation(
            manifestSHA256: sha256(example.source),
            manifestBaseDirectory: URL(fileURLWithPath: example.path)
                .deletingLastPathComponent().path,
            mappingIssues: example.mapping.issues,
            desiredState: example.mapping.desiredState,
            previousDesiredState: previous?.mapping.desiredState,
            observedState: ObservedRuntimeState(
                projectName: projectName,
                services: observedServices,
                adapterMetadata: RuntimeAdapterMetadata(
                    providerID: .appleContainerCLI,
                    adapterName: "phase04-example-driver",
                    adapterVersion: "1",
                    runtimeName: "container",
                    runtimeVersion: "1.1.0",
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                ),
                capabilitySHA256: capabilitySHA256
            ),
            observationSHA256: sha256(
                observedServices
                    .map { "\($0.identity.displayName):\($0.lifecycleState.rawValue)" }
                    .joined(separator: "\n")
            ),
            projectID: "project-\(projectName)",
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-\(projectName)"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            capabilitySHA256: capabilitySHA256,
            planFencingToken: HostwrightResourceUUID.legacy(
                kind: "phase04-example-fence",
                identifier: "\(projectName):\(sha256(example.source))"
            ),
            resourceBindings: bindings
        )
    }

    private func lifecycleBinding(
        observed: ObservedRuntimeService,
        projectName: String
    ) throws -> LifecycleResourceBinding {
        try LifecycleResourceBinding(
            identity: observed.identity,
            resourceIdentifier: observed.resourceIdentifier,
            resourceUUID: HostwrightResourceUUID.legacy(
                kind: "service",
                identifier: observed.identity.displayName
            ),
            resourceGeneration: 1,
            projectResourceUUID: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-\(projectName)"
            ),
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            currentFencingToken: HostwrightResourceUUID.legacy(
                kind: "phase04-example-current-fence",
                identifier: observed.identity.displayName
            )
        )
    }

    private func assertRecoveryExample(
        projectName: String,
        plan: LifecyclePlan,
        temporaryRoot: URL
    ) throws {
        let databasePath = temporaryRoot.appendingPathComponent("recovery.sqlite").path
        let store = SQLiteStateStore(path: databasePath)
        try store.migrate()
        let groupID = HostwrightResourceUUID.generate()
        _ = try store.operationGroups.acquire(
            OperationGroupRecord(
                id: groupID,
                operationID: HostwrightResourceUUID.generate(),
                groupKind: "lifecycle-v1",
                projectID: "project-\(projectName)",
                serviceName: nil,
                plannedActionType: "update",
                status: .active,
                groupIdempotencyKey: plan.planSHA256,
                planHash: plan.planSHA256,
                checkpoint: "rollback-complete",
                lockOwner: nil,
                lockExpiresAt: nil,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "The prior revision was restored.",
                createdAt: "2026-07-23T00:00:00Z",
                updatedAt: "2026-07-23T00:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: plan.nodes.first?.fencingToken ??
                    HostwrightResourceUUID.generate(),
                intentJSONRedacted: try plan.canonicalJSON(),
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: "{}"
            )
        )
        try store.operationGroups.finish(
            groupID: groupID,
            status: .interrupted,
            checkpoint: "rollback-complete",
            manualRecoveryHintRedacted: "The prior revision was restored.",
            updatedAt: "2026-07-23T00:00:01Z",
            metadataJSONRedacted: "{}"
        )

        let result = HostwrightCLI.run(
            arguments: [
                "recovery",
                "--project", projectName,
                "--state-db", databasePath,
                "--output", "json"
            ]
        )
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains(groupID))
        XCTAssertTrue(result.standardOutput.contains(plan.planSHA256))
    }

    private func example(_ relativePath: String) throws -> Example {
        let url = examplesRoot.appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        let manifest = try ManifestValidator.validated(source)
        return Example(
            path: url.path,
            source: source,
            manifest: manifest,
            mapping: ManifestRuntimeMapper.map(
                manifest,
                bindMountBaseDirectory: url.deletingLastPathComponent().path
            )
        )
    }

    private var examplesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples")
    }

    private func withTemporaryRoot(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-phase04-examples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try body(root)
            try FileManager.default.removeItem(at: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct Example {
    let path: String
    let source: String
    let manifest: HostwrightManifest
    let mapping: ManifestRuntimeMappingResult
}

private enum ExampleHarnessError: Error {
    case unexpectedCommand
}

private final class ExampleLifecycleDriver:
    LifecycleCommandDriving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let preparation: LifecycleCommandPreparation
    private let executionStatus: LifecycleSagaExecutionStatus
    private let secretBackendUnavailable: Bool
    private var imageChecks = 0
    private var revalidations = 0
    private var executions = 0

    init(
        preparation: LifecycleCommandPreparation,
        executionStatus: LifecycleSagaExecutionStatus = .succeeded,
        secretBackendUnavailable: Bool = false
    ) {
        self.preparation = preparation
        self.executionStatus = executionStatus
        self.secretBackendUnavailable = secretBackendUnavailable
    }

    var imageCheckCount: Int {
        lock.withLock { imageChecks }
    }

    var revalidationCount: Int {
        lock.withLock { revalidations }
    }

    var executionCount: Int {
        lock.withLock { executions }
    }

    func prepare(options: LifecycleCLIOptions) throws -> LifecycleCommandPreparation {
        if secretBackendUnavailable {
            throw HostwrightDiagnostic(
                code: .manifestUnsupportedFeature,
                message:
                    "The configured secret backend is unavailable. " +
                    "No runtime mutation was attempted."
            )
        }
        return preparation
    }

    func localImageEvidence(
        for requirement: LifecycleLocalImageRequirement,
        preparation: LifecycleCommandPreparation
    ) throws -> RuntimeLocalImageEvidence {
        lock.withLock { imageChecks += 1 }
        return RuntimeLocalImageEvidence(
            reference: requirement.reference,
            descriptorDigest: "sha256:\(String(repeating: "d", count: 64))",
            variantDigest: "sha256:\(String(repeating: "e", count: 64))",
            architecture: requirement.architecture,
            operatingSystem: requirement.operatingSystem
        )
    }

    func revalidate(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation
    ) throws {
        lock.withLock { revalidations += 1 }
    }

    func execute(
        compiled: LifecycleCompiledCommand,
        preparation: LifecycleCommandPreparation,
        options: LifecycleCLIOptions
    ) throws -> LifecycleSagaExecutionResult {
        lock.withLock { executions += 1 }
        return LifecycleSagaExecutionResult(
            status: executionStatus,
            operationID: HostwrightResourceUUID.generate(),
            groupID: HostwrightResourceUUID.generate(),
            planSHA256: compiled.plan.planSHA256,
            checkpoint: executionStatus == .succeeded
                ? "complete"
                : "rollback-complete",
            completedNodeKeys: executionStatus == .succeeded
                ? compiled.plan.nodes.map(\.key)
                : [],
            recoveryHintRedacted: executionStatus == .succeeded
                ? ""
                : "The prior verified revision was restored."
        )
    }
}

private final class ExampleInteractiveDriver:
    InteractiveCommandDriving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let projectName: String
    private var operations: [RuntimeInteractiveOperationKind] = []

    init(projectName: String) {
        self.projectName = projectName
    }

    func execute(
        options: InteractiveCLIOptions,
        sink: @escaping @Sendable (RuntimeStreamEnvelope) throws -> Void
    ) throws -> RuntimeInteractiveExecutionResult {
        let service = try InteractiveOperationBuilder.requestedService(options)
        let operation = try InteractiveOperationBuilder.build(
            options,
            resourceIdentifier: RuntimeServiceIdentity(
                projectName: projectName,
                serviceName: service
            ).managedResourceIdentifier,
            workingDirectory: nil
        )
        lock.withLock { operations.append(operation.kind) }
        try sink(
            RuntimeStreamEnvelope(
                sequence: 0,
                stream: .standardOutput,
                payload: Data(#"{"example":"ok"}"#.utf8)
            )
        )
        try sink(
            RuntimeStreamEnvelope(
                sequence: 1,
                stream: .standardOutput,
                payload: Data(),
                endOfStream: true
            )
        )
        return RuntimeInteractiveExecutionResult(
            operation: operation.kind,
            exitStatus: 0,
            emittedFrameCount: 2,
            standardErrorTail: ""
        )
    }

    func snapshot() -> [RuntimeInteractiveOperationKind] {
        lock.withLock { operations }
    }
}
