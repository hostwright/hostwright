import Darwin
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightState
import XCTest

@testable import HostwrightCLI

final class CLIControlAuthorizationScopeTests: XCTestCase {
    func testApplyAuthorizationScopeWaitsForStateAccessFenceContention() throws {
        try withFixture { fixture in
            let arguments = [
                "apply", fixture.manifestPath,
                "--state-db", fixture.store.path,
                "--confirm-plan", String(repeating: "a", count: 64),
            ]
            let command = try CLICommand.parse(arguments: arguments)
            let lockPath = try fixture.store.configuration.maintenancePaths().accessLockPath
            let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let released = expectation(description: "state-access fence released")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                released.fulfill()
            }

            do {
                let scope = try CLIControlAuthorizationScopeResolver.resolve(
                    command: command,
                    arguments: arguments,
                    environment: fixture.environment
                )
                XCTAssertEqual(scope.projectIdentifier, fixture.projectResourceUUID)
                XCTAssertNil(scope.resourceIdentifier)
            } catch {
                XCTFail("Expected authorization scope resolution after contention: \(error)")
            }
            wait(for: [released], timeout: 1)
        }
    }

    func testReadOnlyExecutionAuthorizationDoesNotWaitBehindLifecycleMutationFence() throws {
        try withFixture { fixture in
            let arguments = [
                "status", fixture.manifestPath,
                "--state-db", fixture.store.path,
                "--output", "json",
            ]
            let command = try CLICommand.parse(arguments: arguments)
            let authorizedScope = try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: arguments,
                environment: fixture.environment
            )
            let hold = try holdLifecycleMutationFence(for: fixture.store)
            defer { releaseAndAssertFenceCompleted(hold) }

            let startedAt = Date()
            let completed = try CLIControlAuthorizationScopeResolver.withExecutionAuthorizationFence(
                command: command,
                arguments: arguments,
                authorizedScope: authorizedScope,
                environment: fixture.environment,
                mutating: false
            ) {
                true
            }

            XCTAssertTrue(completed)
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.200)
        }
    }

    func testMutatingExecutionAuthorizationStillSerializesBehindLifecycleMutationFence() throws {
        try withFixture { fixture in
            let arguments = [
                "apply", fixture.manifestPath,
                "--state-db", fixture.store.path,
                "--confirm-plan", String(repeating: "a", count: 64),
            ]
            let command = try CLICommand.parse(arguments: arguments)
            let authorizedScope = try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: arguments,
                environment: fixture.environment
            )
            let hold = try holdLifecycleMutationFence(for: fixture.store)
            defer { releaseAndAssertFenceCompleted(hold) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.4) {
                hold.release.signal()
            }

            let startedAt = Date()
            let completed = try CLIControlAuthorizationScopeResolver.withExecutionAuthorizationFence(
                command: command,
                arguments: arguments,
                authorizedScope: authorizedScope,
                environment: fixture.environment,
                mutating: true
            ) {
                true
            }

            XCTAssertTrue(completed)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.300)
        }
    }

    func testMutatingExecutionAuthorizationBlocksConcurrentSerializedOwnershipMutation() throws {
        try withFixture { fixture in
            let mutationArguments = [
                "apply", fixture.manifestPath,
                "--state-db", fixture.store.path,
                "--confirm-plan", String(repeating: "a", count: 64),
            ]
            let mutationCommand = try CLICommand.parse(arguments: mutationArguments)
            let readArguments = [
                "logs", "api", fixture.manifestPath, "--state-db", fixture.store.path,
            ]
            let readCommand = try CLICommand.parse(arguments: readArguments)
            let expected = try CLIControlAuthorizationScopeResolver.resolve(
                command: readCommand,
                arguments: readArguments,
                environment: fixture.environment
            )
            let mutationScope = try CLIControlAuthorizationScopeResolver.resolve(
                command: mutationCommand,
                arguments: mutationArguments,
                environment: fixture.environment
            )
            let started = DispatchSemaphore(value: 0)
            let completed = DispatchSemaphore(value: 0)
            let result = ConcurrentResultBox()

            try CLIControlAuthorizationScopeResolver.withExecutionAuthorizationFence(
                command: mutationCommand,
                arguments: mutationArguments,
                authorizedScope: mutationScope,
                environment: fixture.environment,
                mutating: true
            ) {
                DispatchQueue.global(qos: .userInitiated).async {
                    started.signal()
                    result.capture {
                        try StateUpgradeService(store: fixture.store).withSerializedLifecycleMutation {
                            try fixture.store.ownership.upsert(fixture.ownership(
                                id: "ownership-api-replacement",
                                resourceIdentifier: "hostwright-scope-tests-api-replacement",
                                resourceUUID: "22222222-2222-4222-8222-222222222222"
                            ))
                        }
                    }
                    completed.signal()
                }
                XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
                XCTAssertEqual(completed.wait(timeout: .now() + 0.100), .timedOut)
                XCTAssertEqual(
                    try CLIControlAuthorizationScopeResolver.resolve(
                        command: readCommand,
                        arguments: readArguments,
                        environment: fixture.environment
                    ),
                    expected
                )
            }

            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            XCTAssertNil(result.error)
            XCTAssertThrowsError(try CLIControlAuthorizationScopeResolver.resolve(
                command: readCommand,
                arguments: readArguments,
                environment: fixture.environment
            )) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .stateStoreUnavailable)
            }
        }
    }

    func testReadOnlyExecutionAuthorizationFailsClosedWhenOwnershipChangesDuringBody() throws {
        try withFixture { fixture in
            let arguments = [
                "logs", "api", fixture.manifestPath, "--state-db", fixture.store.path,
            ]
            let command = try CLICommand.parse(arguments: arguments)
            let authorizedScope = try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: arguments,
                environment: fixture.environment
            )

            XCTAssertThrowsError(try CLIControlAuthorizationScopeResolver
                .withExecutionAuthorizationFence(
                    command: command,
                    arguments: arguments,
                    authorizedScope: authorizedScope,
                    environment: fixture.environment,
                    mutating: false
                ) {
                    try StateUpgradeService(store: fixture.store).withSerializedLifecycleMutation {
                        try fixture.store.ownership.upsert(fixture.ownership(
                            id: "ownership-api-concurrent",
                            resourceIdentifier: "hostwright-scope-tests-api-concurrent",
                            resourceUUID: "22222222-2222-4222-8222-222222222222"
                        ))
                    }
                    return "in-memory result"
                }
            ) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .stateStoreUnavailable)
            }
        }
    }

    func testManifestBackedSingleServiceResolvesAuthoritativeProjectAndResourceUUID() throws {
        try withFixture { fixture in
            let command = try CLICommand.parse(arguments: [
                "logs", "api", fixture.manifestPath, "--state-db", fixture.store.path,
            ])
            let scope = try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: ["logs", "api", fixture.manifestPath, "--state-db", fixture.store.path],
                environment: fixture.environment
            )

            XCTAssertEqual(scope.projectIdentifier, fixture.projectResourceUUID)
            XCTAssertEqual(scope.resourceIdentifier, fixture.apiResourceUUID)
        }
    }

    func testAmbiguousManifestServiceOwnershipIsRejectedRatherThanChoosingOneResource() throws {
        try withFixture { fixture in
            try fixture.store.ownership.upsert(fixture.ownership(
                id: "ownership-api-duplicate",
                resourceIdentifier: "hostwright-scope-tests-api-duplicate",
                resourceUUID: "22222222-2222-4222-8222-222222222222"
            ))
            let command = try CLICommand.parse(arguments: [
                "logs", "api", fixture.manifestPath, "--state-db", fixture.store.path,
            ])

            XCTAssertThrowsError(try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: ["logs", "api", fixture.manifestPath, "--state-db", fixture.store.path],
                environment: fixture.environment
            )) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .stateStoreUnavailable)
            }
        }
    }

    func testMultipleRequestedServicesRetainProjectScopeWithoutInventingAResourceScope() throws {
        try withFixture { fixture in
            let arguments = [
                "start", fixture.manifestPath,
                "--service", "api", "--service", "worker",
                "--state-db", fixture.store.path, "--dry-run",
            ]
            let command = try CLICommand.parse(arguments: arguments)
            let scope = try CLIControlAuthorizationScopeResolver.resolve(
                command: command,
                arguments: arguments,
                environment: fixture.environment
            )

            XCTAssertEqual(scope.projectIdentifier, fixture.projectResourceUUID)
            XCTAssertNil(scope.resourceIdentifier)
        }
    }

    func testDeclaredScopeMismatchIsRejectedAgainstTheAuthoritativeManifestAndState() throws {
        try withFixture { fixture in
            let arguments = ["logs", "api", fixture.manifestPath, "--state-db", fixture.store.path]
            let command = try CLICommand.parse(arguments: arguments)

            XCTAssertThrowsError(try CLIControlAuthorizationScopeResolver.validate(
                declared: CLIControlAuthorizationScope(
                    projectIdentifier: "project-scope-tests",
                    resourceIdentifier: "22222222-2222-4222-8222-222222222222"
                ),
                command: command,
                arguments: arguments,
                environment: fixture.environment
            )) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
            }
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-cli-control-scope-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestPath = root.appendingPathComponent("hostwright.yaml").path
        let manifestText = """
        version: 3
        project: scope-tests
        services:
          api:
            image: ghcr.io/example/api:latest
          worker:
            image: ghcr.io/example/worker:latest
        """
        try manifestText.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let manifest = try ManifestValidator.validated(manifestText)
        try store.desiredStates.saveManifestSnapshot(
            projectID: "project-scope-tests",
            manifestPath: manifestPath,
            manifestHash: String(repeating: "a", count: 64),
            desiredGeneration: 1,
            manifest: manifest,
            timestamp: "2026-08-03T00:00:00Z",
            mutationProvider: "apple-cli"
        )
        let fixture = Fixture(
            root: root,
            manifestPath: manifestPath,
            manifestText: manifestText,
            store: store,
            apiResourceUUID: "11111111-1111-4111-8111-111111111111"
        )
        try store.ownership.upsert(fixture.ownership(
            id: "ownership-api",
            resourceIdentifier: "hostwright-scope-tests-api",
            resourceUUID: fixture.apiResourceUUID
        ))
        try body(fixture)
    }

    private func holdLifecycleMutationFence(
        for store: SQLiteStateStore
    ) throws -> LifecycleFenceHold {
        let hold = LifecycleFenceHold()
        DispatchQueue.global(qos: .userInitiated).async {
            hold.result.capture {
                try StateUpgradeService(store: store).withSerializedLifecycleMutation(
                    lockWaitMilliseconds: 1_000
                ) {
                    hold.acquired.signal()
                    guard hold.release.wait(timeout: .now() + 2) == .success else {
                        throw NSError(domain: "CLIControlAuthorizationScopeTests", code: 1)
                    }
                }
            }
            hold.finished.signal()
        }
        guard hold.acquired.wait(timeout: .now() + 1) == .success else {
            hold.release.signal()
            _ = hold.finished.wait(timeout: .now() + 1)
            if let error = hold.result.error { throw error }
            throw NSError(domain: "CLIControlAuthorizationScopeTests", code: 2)
        }
        return hold
    }

    private func releaseAndAssertFenceCompleted(_ hold: LifecycleFenceHold) {
        hold.release.signal()
        XCTAssertEqual(hold.finished.wait(timeout: .now() + 1), .success)
        XCTAssertNil(hold.result.error)
    }

    private struct Fixture {
        let root: URL
        let manifestPath: String
        let manifestText: String
        let store: SQLiteStateStore
        let apiResourceUUID: String

        var projectResourceUUID: String {
            HostwrightResourceUUID.legacy(
                kind: "project", identifier: "project-scope-tests")
        }

        var environment: CLIEnvironment {
            let resolution = try! HostwrightLocalPathResolver.resolve(
                explicitStateDatabasePath: store.path,
                homeDirectory: root.path,
                environment: [:]
            )
            return CLIEnvironment(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
                writeTextFile: { _, _ in },
                executablePath: { _ in nil },
                localPathResolution: { _ in resolution },
                swiftVersion: { "Swift test" },
                platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
                operatingSystemDescription: { "macOS test" }
            )
        }

        func ownership(id: String, resourceIdentifier: String, resourceUUID: String) -> OwnershipRecord {
            OwnershipRecord(
                id: id,
                resourceIdentifier: resourceIdentifier,
                resourceType: "container",
                projectID: "project-scope-tests",
                serviceName: "api",
                runtimeAdapter: "apple-cli",
                createdAt: "2026-08-03T00:00:00Z",
                observedAt: "2026-08-03T00:00:00Z",
                cleanupEligible: true,
                metadataJSONRedacted: "{}",
                resourceUUID: resourceUUID,
                fencingToken: "33333333-3333-4333-8333-333333333333"
            )
        }
    }
}

private final class ConcurrentResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.withLock { storedError }
    }

    func capture(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            lock.withLock { storedError = error }
        }
    }
}

private final class LifecycleFenceHold: @unchecked Sendable {
    let acquired = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = ConcurrentResultBox()
}
