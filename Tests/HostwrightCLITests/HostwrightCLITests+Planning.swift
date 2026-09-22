import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

extension HostwrightCLITests {
    func testValidateAndPlanRemainNonMutatingWhileStatusUsesSecureDefaultState() throws {
        try withCLITestDirectory(prefix: "hostwright-cli-xctest") { home in
            let validFiles = FileBox(files: [HostwrightIdentity.manifestFileName: HostwrightCLI.starterManifest])
            let resolution = try HostwrightLocalPathResolver.resolve(homeDirectory: home.path, environment: [:])
            let observed = ObservedRuntimeState(
                projectName: "api-local",
                services: [],
                adapterMetadata: fakeAdapterMetadata
            )
            let testEnvironment = environment(
                files: validFiles,
                runtimeAdapter: ScriptedApplyRuntimeAdapter(observedState: observed),
                localPathResolution: { explicitPath in
                    try HostwrightLocalPathResolver.resolve(
                        explicitStateDatabasePath: explicitPath,
                        homeDirectory: home.path,
                        environment: [:]
                    )
                }
            )

            let validateResult = HostwrightCLI.run(arguments: ["validate"], environment: testEnvironment)
            XCTAssertEqual(validateResult.exitCode, 0)
            XCTAssertTrue(validateResult.standardOutput.contains("Valid hostwright manifest"))

            let planResult = HostwrightCLI.run(arguments: ["plan"], environment: testEnvironment)
            XCTAssertEqual(planResult.exitCode, 0)
            XCTAssertTrue(planResult.standardOutput.contains("non-mutating"))
            XCTAssertTrue(planResult.standardOutput.contains("Runtime observation"))
            XCTAssertTrue(planResult.standardOutput.contains("Plan hash"))
            XCTAssertTrue(planResult.standardOutput.contains("Execution: unavailable unless one createMissingService, startManagedService, or restartManagedService action is explicitly confirmed"))
            XCTAssertTrue(planResult.standardOutput.contains("No runtime actions were executed"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))

            let statusResult = HostwrightCLI.run(arguments: ["status"], environment: testEnvironment)
            XCTAssertEqual(statusResult.exitCode, 0)
            XCTAssertTrue(statusResult.standardOutput.contains("Runtime: observed"))
            XCTAssertTrue(statusResult.standardOutput.contains("State DB: \(resolution.stateDatabasePath)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: resolution.stateDatabasePath))
            XCTAssertEqual(try permissions(resolution.stateDatabasePath), 0o600)
        }
    }

    func testPlanOutputRedactsSecretLikeEnvironmentValues() {
        let files = FileBox(
            files: [
                HostwrightIdentity.manifestFileName: """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests:
                        cpus: 1
                        memory: 512MiB
                      limits:
                        cpus: 1
                        memory: 512MiB
                    secretEnv:
                      API_TOKEN: keychain://hostwright.api/api-token

                """
            ]
        )

        let planResult = HostwrightCLI.run(arguments: ["plan"], environment: environment(files: files))

        XCTAssertEqual(planResult.exitCode, 0)
        XCTAssertTrue(planResult.standardOutput.contains("secretRedacted"))
        XCTAssertTrue(planResult.standardOutput.contains("API_TOKEN"))
        XCTAssertFalse(planResult.standardOutput.contains("hostwright.api"))
        XCTAssertFalse(planResult.standardOutput.contains("api-token"))
    }

    func testPlanJSONOutputIncludesStableShapeAndRedactsSecrets() throws {
        let files = FileBox(
            files: [
                HostwrightIdentity.manifestFileName: """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests:
                        cpus: 1
                        memory: 512MiB
                      limits:
                        cpus: 1
                        memory: 512MiB
                    secretEnv:
                      API_TOKEN: keychain://hostwright.api/api-token

                """
            ]
        )

        let result = HostwrightCLI.run(arguments: ["plan", "--output", "json"], environment: environment(files: files))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(result.standardOutput.contains(fakeSecret))
        XCTAssertFalse(result.standardOutput.contains("hostwright.api"))
        XCTAssertFalse(result.standardOutput.contains("api-token"))
        let json = try jsonObject(result.standardOutput)
        XCTAssertEqual(json["kind"] as? String, "plan")
        XCTAssertEqual(json["project"] as? String, "api-local")
        XCTAssertNotNil(json["planHash"])
        let issues = try XCTUnwrap(json["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["kind"] as? String == "secretRedacted" })
    }

    func testStatusPlanHashMatchesApplyForPersistedHealthManagedRestart() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            let observedUnknown = runningObservedService(healthState: .unknown)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnknown)

            let status = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let statusHash = try planHash(fromStatusOutput: status.standardOutput)
            XCTAssertTrue(status.standardOutput.contains("health=unhealthy"))

            let apply = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", statusHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(apply.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(apply.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }

    func testPlanningHealthOverlayPreservesExactResourceIdentifierAndNetworks() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: managedRestartHealthManifest)
            try saveFreshUnhealthyHealthResult(store: store)
            let desiredState = ManifestRuntimeMapper.map(
                try ManifestValidator.validated(managedRestartHealthManifest)
            ).desiredState
            let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
            let network = RuntimeNetworkAttachment(
                name: "default",
                hostname: "api.local",
                ipv4Address: "192.168.64.8/24",
                mtu: 1500
            )
            let observed = ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: identity,
                        resourceIdentifier: identity.legacyManagedResourceIdentifier,
                        image: "local/demo:latest",
                        lifecycleState: .running,
                        healthState: .unknown,
                        networks: [network]
                    )
                ],
                adapterMetadata: fakeAdapterMetadata
            )

            let overlaid = try hostwrightPlanningObservedState(
                observed: observed,
                desiredState: desiredState,
                store: store,
                projectID: "project-demo",
                currentTimestamp: hostwrightTimestamp()
            )

            let service = try XCTUnwrap(overlaid.services.first)
            XCTAssertEqual(service.healthState, .unhealthy)
            XCTAssertEqual(service.resourceIdentifier, identity.legacyManagedResourceIdentifier)
            XCTAssertEqual(service.networks, [network])
        }
    }

    func testStatusPlanHashMatchesApplyForRestartPolicyBlockedManagedRestart() throws {
        try withCLITestDatabase(prefix: "hostwright-cli-xctest") { databasePath in
            let manifestText = managedRestartHealthManifest
            let files = FileBox(files: [HostwrightIdentity.manifestFileName: manifestText])
            let store = SQLiteStateStore(path: databasePath)
            try store.migrate()
            try saveDesiredManifest(store: store, manifestText: manifestText)
            try saveOwnership(store: store)
            try saveFreshUnhealthyHealthResult(store: store)
            try store.restartPolicies.upsert(
                RestartPolicyStateRecord(
                    id: "restart-state-api",
                    projectID: "project-demo",
                    serviceName: "api",
                    policy: .onFailure,
                    status: .crashLoopBlocked,
                    attemptCount: 3,
                    maxAttempts: 3,
                    backoffSeconds: 60,
                    updatedAt: hostwrightTimestamp(),
                    metadataJSONRedacted: "{}"
                )
            )
            let observedUnknown = runningObservedService(healthState: .unknown)
            let adapter = ScriptedApplyRuntimeAdapter(observedState: observedUnknown)

            let status = HostwrightCLI.run(
                arguments: ["status", "--state-db", databasePath],
                environment: environment(files: files, runtimeAdapter: adapter)
            )
            let statusHash = try planHash(fromStatusOutput: status.standardOutput)
            XCTAssertTrue(status.standardOutput.contains("health=unhealthy"))

            let apply = HostwrightCLI.run(
                arguments: ["apply", "--state-db", databasePath, "--confirm-plan", statusHash],
                environment: environment(files: files, runtimeAdapter: adapter)
            )

            XCTAssertEqual(apply.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(apply.standardError.contains("Manifest-only admission cannot authorize runtime mutation."))
            XCTAssertTrue(apply.standardError.contains("crash-loop protection"))
            XCTAssertTrue(adapter.executedActions.isEmpty)
        }
    }
}
