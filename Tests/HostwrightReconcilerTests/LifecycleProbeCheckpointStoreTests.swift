import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightState

final class LifecycleProbeCheckpointStoreTests: XCTestCase {
    func testProbeCheckpointResumesAfterIndependentProcessExit() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment[ProbeRestartEnvironment.child] == "1" {
            try ProbeRestartFixture.load(environment: environment)
                .writeInFlightCheckpoint()
            return
        }

        let fixture = try ProbeRestartFixture.make()
        var requiresCleanup = true
        defer {
            if requiresCleanup {
                try? fixture.cleanup()
            }
        }

        let process = try launchProbeRestartChild(fixture: fixture)
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw ProbeRestartError.childTimedOut
        }
        process.waitUntilExit()
        let diagnostics = childDiagnostics(process)
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw ProbeRestartError.childFailed(diagnostics)
        }

        let reopened = SQLiteStateStore(path: fixture.databaseURL.path)
        XCTAssertEqual(try reopened.schemaVersion(), 7)
        let group = try XCTUnwrap(
            reopened.operationGroups.load(id: fixture.groupID)
        )
        XCTAssertEqual(group.fencingToken, fixture.fence)
        let persisted = try XCTUnwrap(
            LifecycleProbeCheckpointStore(store: reopened).loadLatest(
                groupID: fixture.groupID,
                resourceIdentifier: fixture.resourceIdentifier
            )
        )
        XCTAssertEqual(persisted.resourceIdentifier, fixture.resourceIdentifier)
        XCTAssertEqual(persisted.state(for: .readiness)?.phase, .executing)
        XCTAssertEqual(persisted.state(for: .readiness)?.inFlightAttempt, 1)

        let first = try RuntimeProbeStateMachine.resumed(
            persisted,
            probes: fixture.probes,
            nowMilliseconds: 5_000
        )
        let second = try RuntimeProbeStateMachine.resumed(
            persisted,
            probes: fixture.probes,
            nowMilliseconds: 5_000
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.resourceIdentifier, fixture.resourceIdentifier)
        XCTAssertEqual(first.state(for: .readiness)?.phase, .waiting)
        XCTAssertNil(first.state(for: .readiness)?.inFlightAttempt)
        XCTAssertEqual(
            first.state(for: .readiness)?.nextAttemptAtMilliseconds,
            5_000
        )
        let step = try XCTUnwrap(
            reopened.operationGroupSteps.load(groupID: fixture.groupID).last
        )
        XCTAssertEqual(step.groupID, fixture.groupID)
        XCTAssertEqual(step.resourceIdentifier, fixture.resourceIdentifier)
        XCTAssertEqual(step.status, .started)

        try fixture.cleanup()
        requiresCleanup = false
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.directory.path)
        )
    }

    func testProbeSnapshotPersistsInTheFencedSchemaV7OperationGroupAndResumes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let probes = RuntimeProbeSet(
            startup: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/usr/bin/startup"]))
            )
        )
        let initial = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "hostwright-demo-api",
            probes: probes,
            startedAtMilliseconds: 1_000
        )
        let started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .startup,
            probes: probes,
            snapshot: initial,
            nowMilliseconds: 1_000
        ).snapshot
        let checkpoints = LifecycleProbeCheckpointStore(store: fixture.store)

        try checkpoints.save(
            started,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            serviceName: "api",
            updatedAt: "2026-07-23T00:00:01Z"
        )
        let persisted = try XCTUnwrap(
            checkpoints.loadLatest(
                groupID: fixture.groupID,
                resourceIdentifier: "hostwright-demo-api"
            )
        )
        XCTAssertEqual(persisted, started)
        let resumed = try RuntimeProbeStateMachine.resumed(
            persisted,
            probes: probes,
            nowMilliseconds: 2_000
        )
        XCTAssertEqual(resumed.state(for: .startup)?.phase, .waiting)
        XCTAssertEqual(resumed.state(for: .startup)?.nextAttemptAtMilliseconds, 2_000)
    }

    func testProbeCheckpointRedactsAndBoundsDiagnostics() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let oversizedSecret = "token=super-secret-" + String(repeating: "x", count: 8_192)
        let snapshot = RuntimeProbeSnapshot(
            resourceIdentifier: "hostwright-demo-api",
            startedAtMilliseconds: 1_000,
            states: [
                RuntimeProbeState(
                    kind: .liveness,
                    phase: .failed,
                    consecutiveFailures: 3,
                    attemptCount: 3,
                    nextAttemptAtMilliseconds: 2_000,
                    lastOutcome: .failed,
                    lastDiagnosticRedacted: oversizedSecret
                )
            ]
        )
        let checkpoints = LifecycleProbeCheckpointStore(store: fixture.store)

        try checkpoints.save(
            snapshot,
            groupID: fixture.groupID,
            fencingToken: fixture.fence,
            serviceName: "api",
            updatedAt: "2026-07-23T00:00:01Z"
        )

        let persisted = try XCTUnwrap(
            checkpoints.loadLatest(
                groupID: fixture.groupID,
                resourceIdentifier: "hostwright-demo-api"
            )
        )
        let diagnostic = try XCTUnwrap(persisted.state(for: .liveness)?.lastDiagnosticRedacted)
        XCTAssertLessThanOrEqual(diagnostic.utf8.count, RuntimeProbeAttemptResult.maximumDiagnosticBytes)
        XCTAssertFalse(diagnostic.contains("super-secret"))
        let row = try XCTUnwrap(
            fixture.store.operationGroupSteps.load(groupID: fixture.groupID).last
        )
        XCTAssertEqual(row.status, .failed)
        XCTAssertFalse(row.metadataJSONRedacted.contains("super-secret"))
    }

    func testWrongFenceCannotPersistProbeCheckpoint() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "hostwright-demo-api",
            probes: RuntimeProbeSet(
                readiness: RuntimeProbeConfiguration(
                    action: .tcp(RuntimeProbeTCPAction(port: 8080))
                )
            ),
            startedAtMilliseconds: 1_000
        )

        XCTAssertThrowsError(
            try LifecycleProbeCheckpointStore(store: fixture.store).save(
                snapshot,
                groupID: fixture.groupID,
                fencingToken: HostwrightResourceUUID.generate(),
                serviceName: "api",
                updatedAt: "2026-07-23T00:00:01Z"
            )
        )
        XCTAssertTrue(try fixture.store.operationGroupSteps.load(groupID: fixture.groupID).isEmpty)
    }

    private func makeFixture() throws -> ProbeCheckpointFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-probe-checkpoint-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let groupID = HostwrightResourceUUID.generate()
        let operationID = HostwrightResourceUUID.generate()
        let fence = HostwrightResourceUUID.generate()
        let acquired = try store.operationGroups.acquire(
            OperationGroupRecord(
                id: groupID,
                operationID: operationID,
                groupKind: "lifecycle-v1",
                projectID: "project-demo",
                serviceName: nil,
                plannedActionType: "up",
                status: .active,
                groupIdempotencyKey: String(repeating: "a", count: 64),
                planHash: String(repeating: "a", count: 64),
                checkpoint: "intent-persisted",
                lockOwner: "probe-checkpoint-test",
                lockExpiresAt: nil,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-07-23T00:00:00Z",
                updatedAt: "2026-07-23T00:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: fence,
                intentJSONRedacted: "{}",
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: "{}"
            )
        )
        XCTAssertNotNil(acquired.acquired)
        return ProbeCheckpointFixture(
            directory: directory,
            store: store,
            groupID: groupID,
            fence: fence
        )
    }

    private func launchProbeRestartChild(
        fixture: ProbeRestartFixture
    ) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        guard bundle.pathExtension == "xctest",
              FileManager.default.fileExists(atPath: bundle.path) else {
            throw ProbeRestartError.testBundleUnavailable
        }
        let process = Process()
        let parentEnvironment = ProcessInfo.processInfo.environment
        let sanitizerRuntime = parentEnvironment["DYLD_INSERT_LIBRARIES"]
            ?? parentEnvironment["HOSTWRIGHT_TEST_DYLD_INSERT_LIBRARIES"]
        let testSelector = "HostwrightReconcilerTests.LifecycleProbeCheckpointStoreTests/testProbeCheckpointResumesAfterIndependentProcessExit"
        if sanitizerRuntime != nil {
            let developerDirectory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
                ?? "/Applications/Xcode.app/Contents/Developer"
            let xctest = URL(fileURLWithPath: developerDirectory)
                .appendingPathComponent("usr/bin/xctest")
            if FileManager.default.fileExists(atPath: xctest.path) {
                process.executableURL = xctest
                process.arguments = ["-XCTest", testSelector, bundle.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = ["xctest", "-XCTest", testSelector, bundle.path]
            }
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["xctest", "-XCTest", testSelector, bundle.path]
        }
        var environment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            ProbeRestartEnvironment.child: "1",
            ProbeRestartEnvironment.directory: fixture.directory.path,
            ProbeRestartEnvironment.token: fixture.token
        ]
        for key in [
            "DYLD_INSERT_LIBRARIES",
            "ASAN_OPTIONS",
            "TSAN_OPTIONS",
            "UBSAN_OPTIONS",
            "MallocNanoZone"
        ] {
            if let value = parentEnvironment[key] {
                environment[key] = value
            }
        }
        if environment["DYLD_INSERT_LIBRARIES"] == nil,
           let sanitizerRuntime {
            environment["DYLD_INSERT_LIBRARIES"] = sanitizerRuntime
        }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func childDiagnostics(_ process: Process) -> String {
        let standardOutput = (process.standardOutput as? Pipe)?
            .fileHandleForReading.readDataToEndOfFile() ?? Data()
        let standardError = (process.standardError as? Pipe)?
            .fileHandleForReading.readDataToEndOfFile() ?? Data()
        return [
            String(decoding: standardOutput, as: UTF8.self),
            String(decoding: standardError, as: UTF8.self)
        ].joined(separator: "\n")
    }
}

private struct ProbeCheckpointFixture {
    let directory: URL
    let store: SQLiteStateStore
    let groupID: String
    let fence: String

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum ProbeRestartEnvironment {
    static let child = "HOSTWRIGHT_PROBE_RESTART_CHILD"
    static let directory = "HOSTWRIGHT_PROBE_RESTART_DIRECTORY"
    static let token = "HOSTWRIGHT_PROBE_RESTART_TOKEN"
}

private enum ProbeRestartError: Error {
    case invalidFixture
    case testBundleUnavailable
    case childTimedOut
    case childFailed(String)
}

private struct ProbeRestartFixture {
    static let ownerFileName = ".hostwright-probe-restart-owned"
    static let databaseFileName = "state.sqlite"

    let directory: URL
    let token: String

    var databaseURL: URL {
        directory.appendingPathComponent(Self.databaseFileName)
    }

    var ownerURL: URL {
        directory.appendingPathComponent(Self.ownerFileName)
    }

    var operationID: String {
        HostwrightResourceUUID.legacy(
            kind: "probe-restart-operation",
            identifier: token
        )
    }

    var groupID: String {
        HostwrightResourceUUID.legacy(
            kind: "probe-restart-group",
            identifier: token
        )
    }

    var fence: String {
        HostwrightResourceUUID.legacy(
            kind: "probe-restart-fence",
            identifier: token
        )
    }

    var resourceIdentifier: String {
        "hostwright-probe-restart-\(token)"
    }

    var probes: RuntimeProbeSet {
        RuntimeProbeSet(
            readiness: RuntimeProbeConfiguration(
                action: .exec(
                    RuntimeProbeExecAction(command: ["/usr/bin/ready"])
                ),
                intervalSeconds: 3,
                timeoutSeconds: 2,
                successThreshold: 1,
                failureThreshold: 2
            )
        )
    }

    static func make() throws -> ProbeRestartFixture {
        let token = UUID().uuidString.lowercased()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-probe-restart-\(token)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let fixture = ProbeRestartFixture(
            directory: directory,
            token: token
        )
        try Data((token + "\n").utf8).write(
            to: fixture.ownerURL,
            options: .withoutOverwriting
        )
        return fixture
    }

    static func load(
        environment: [String: String]
    ) throws -> ProbeRestartFixture {
        guard let path = environment[ProbeRestartEnvironment.directory],
              let token = environment[ProbeRestartEnvironment.token] else {
            throw ProbeRestartError.invalidFixture
        }
        let fixture = ProbeRestartFixture(
            directory: URL(fileURLWithPath: path, isDirectory: true),
            token: token
        )
        guard fixture.isOwned else {
            throw ProbeRestartError.invalidFixture
        }
        return fixture
    }

    func writeInFlightCheckpoint() throws {
        guard isOwned else {
            throw ProbeRestartError.invalidFixture
        }
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        guard try store.schemaVersion() == 7 else {
            throw ProbeRestartError.invalidFixture
        }
        let acquired = try store.operationGroups.acquire(
            OperationGroupRecord(
                id: groupID,
                operationID: operationID,
                groupKind: "lifecycle-v1",
                projectID: "project-probe-restart",
                serviceName: nil,
                plannedActionType: "up",
                status: .active,
                groupIdempotencyKey: String(repeating: "a", count: 64),
                planHash: String(repeating: "a", count: 64),
                checkpoint: "intent-persisted",
                lockOwner: "probe-restart-child",
                lockExpiresAt: nil,
                rollbackAvailable: true,
                manualRecoveryHintRedacted: "",
                createdAt: "2026-07-23T00:00:00Z",
                updatedAt: "2026-07-23T00:00:00Z",
                metadataJSONRedacted: "{}",
                fencingToken: fence,
                intentJSONRedacted: "{}",
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: "{}"
            )
        )
        guard acquired.acquired != nil else {
            throw ProbeRestartError.invalidFixture
        }
        let initial = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: resourceIdentifier,
            probes: probes,
            startedAtMilliseconds: 1_000
        )
        let inFlight = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .readiness,
            probes: probes,
            snapshot: initial,
            nowMilliseconds: 1_000
        ).snapshot
        try LifecycleProbeCheckpointStore(store: store).save(
            inFlight,
            groupID: groupID,
            fencingToken: fence,
            serviceName: "api",
            updatedAt: "2026-07-23T00:00:01Z"
        )
    }

    func cleanup() throws {
        guard isOwned else {
            throw ProbeRestartError.invalidFixture
        }
        try FileManager.default.removeItem(at: directory)
    }

    private var isOwned: Bool {
        let normalized = URL(
            fileURLWithPath: NSString(string: directory.path).standardizingPath,
            isDirectory: true
        )
        guard normalized.path == directory.path,
              directory.lastPathComponent == "hostwright-probe-restart-\(token)",
              let owner = try? String(contentsOf: ownerURL, encoding: .utf8),
              owner == token + "\n" else {
            return false
        }
        return true
    }
}
