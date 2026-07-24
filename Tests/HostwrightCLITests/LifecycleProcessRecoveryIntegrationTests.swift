import Darwin
import Foundation
import HostwrightCore
import HostwrightReconciler
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class LifecycleProcessRecoveryIntegrationTests: XCTestCase {
    func testLifecycleSagaRecoversAfterSIGKILLAtDurableBoundaries() async throws {
        let environment = ProcessInfo.processInfo.environment
        if environment[ProcessRecoveryEnvironment.worker] == "1" {
            let foundation = try ProcessRecoveryFoundation.load(
                environment: environment
            )
            try await foundation.runWorker()
            return
        }

        for scenario in ProcessRecoveryScenario.allCases {
            let foundation = try ProcessRecoveryFoundation.make(scenario: scenario)
            do {
                XCTAssertEqual(try foundation.store.schemaVersion(), 7)
                let killed = try launchWorker(
                    foundation: foundation,
                    stage: .kill
                )
                try assertKillBoundary(
                    foundation: foundation,
                    process: killed
                )
                let resumed = try launchWorker(
                    foundation: foundation,
                    stage: .resume
                )
                try waitForCleanExit(resumed, scenario: scenario)
                try assertRecovered(foundation)
                try foundation.remove()
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: foundation.directory.path)
                )
            } catch {
                if FileManager.default.fileExists(atPath: foundation.directory.path) {
                    try? foundation.remove()
                }
                throw error
            }
        }
    }

    private func launchWorker(
        foundation: ProcessRecoveryFoundation,
        stage: ProcessRecoveryStage
    ) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        guard bundle.pathExtension == "xctest",
              FileManager.default.fileExists(atPath: bundle.path) else {
            throw ProcessRecoveryError.testBundleUnavailable
        }
        let process = Process()
        let parentEnvironment = ProcessInfo.processInfo.environment
        let sanitizerRuntime = parentEnvironment["DYLD_INSERT_LIBRARIES"]
            ?? parentEnvironment["HOSTWRIGHT_TEST_DYLD_INSERT_LIBRARIES"]
        let testSelector = "HostwrightCLITests.LifecycleProcessRecoveryIntegrationTests/testLifecycleSagaRecoversAfterSIGKILLAtDurableBoundaries"
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
            ProcessRecoveryEnvironment.worker: "1",
            ProcessRecoveryEnvironment.directory: foundation.directory.path,
            ProcessRecoveryEnvironment.scenario: foundation.scenario.rawValue,
            ProcessRecoveryEnvironment.stage: stage.rawValue
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

    private func assertKillBoundary(
        foundation: ProcessRecoveryFoundation,
        process: Process
    ) throws {
        guard waitForReadyMarker(foundation.readyURL, process: process) else {
            let diagnostics = terminateAndCollect(process)
            throw ProcessRecoveryError.workerDidNotReachBoundary(diagnostics)
        }
        let group = try XCTUnwrap(
            foundation.store.operationGroups.load(id: foundation.groupID)
        )
        XCTAssertEqual(group.status, .active)
        XCTAssertEqual(group.planHash, foundation.plan.planSHA256)
        XCTAssertEqual(group.fencingToken, foundation.fence)
        XCTAssertNotNil(group.lockExpiresAt)
        XCTAssertEqual(
            try LifecyclePersistedIntentCodec.decode(group.intentJSONRedacted),
            foundation.plan
        )
        switch foundation.scenario {
        case .intentPending, .effectSatisfied, .effectPartial, .effectAmbiguous:
            XCTAssertEqual(group.checkpoint, "create-primary:effect-pending")
        case .verifiedCheckpoint:
            XCTAssertEqual(group.checkpoint, "start-primary:effect-pending")
            let steps = try foundation.store.operationGroupSteps.load(
                groupID: foundation.groupID
            )
            XCTAssertEqual(
                steps.filter {
                    $0.stepKey == "create-primary" && $0.status == .succeeded
                }.count,
                1
            )
        case .compensationCheckpoint:
            XCTAssertEqual(
                group.checkpoint,
                "create-primary:compensation-pending"
            )
        }

        XCTAssertEqual(Darwin.kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        errno = 0
        XCTAssertEqual(Darwin.kill(process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        try FileManager.default.removeItem(at: foundation.readyURL)
    }

    private func assertRecovered(_ foundation: ProcessRecoveryFoundation) throws {
        let group = try XCTUnwrap(
            foundation.store.operationGroups.load(id: foundation.groupID)
        )
        XCTAssertNil(group.lockOwner)
        XCTAssertNil(group.lockExpiresAt)
        let ledger = try ProcessRecoveryLedger.read(foundation.ledgerURL)
        let primaryApplyCount = ledger.count(
            event: .applySatisfied,
            node: "create-primary"
        ) + ledger.count(event: .applyPartial, node: "create-primary") +
            ledger.count(event: .applyAmbiguous, node: "create-primary")
        XCTAssertEqual(primaryApplyCount, 1)

        switch foundation.scenario {
        case .intentPending:
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(group.checkpoint, "verified")
            XCTAssertEqual(
                ledger.count(event: .compensate, node: "create-primary"),
                0
            )
            let started = try foundation.store.operationGroupSteps.load(
                groupID: foundation.groupID
            ).filter {
                $0.stepKey == "create-primary" &&
                    $0.direction == .forward &&
                    $0.status == .started
            }
            XCTAssertEqual(started.count, 2)
        case .effectSatisfied:
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(group.checkpoint, "verified")
            XCTAssertEqual(
                ledger.count(event: .compensate, node: "create-primary"),
                0
            )
        case .effectPartial, .compensationCheckpoint:
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(group.checkpoint, "compensated")
            XCTAssertEqual(
                ledger.count(event: .compensate, node: "create-primary"),
                1
            )
            XCTAssertEqual(ledger.state(of: "create-primary"), .absent)
        case .effectAmbiguous:
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(
                group.checkpoint,
                "create-primary:ambiguous-after-resume"
            )
            XCTAssertEqual(
                ledger.count(event: .compensate, node: "create-primary"),
                0
            )
            XCTAssertEqual(ledger.state(of: "create-primary"), .ambiguous)
        case .verifiedCheckpoint:
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(group.checkpoint, "verified")
            XCTAssertEqual(
                ledger.count(event: .applySatisfied, node: "create-primary"),
                1
            )
            XCTAssertEqual(
                ledger.count(event: .applySatisfied, node: "start-primary"),
                1
            )
            let steps = try foundation.store.operationGroupSteps.load(
                groupID: foundation.groupID
            )
            XCTAssertEqual(
                steps.filter {
                    $0.stepKey == "create-primary" &&
                        $0.direction == .forward &&
                        $0.status == .started
                }.count,
                1
            )
            XCTAssertEqual(
                steps.filter {
                    $0.stepKey == "create-primary" &&
                        $0.direction == .forward &&
                        $0.status == .succeeded
                }.count,
                1
            )
        }
    }

    private func waitForReadyMarker(_ url: URL, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if ProcessRecoveryFoundation.validReadyMarker(url) {
                return true
            }
            if !process.isRunning {
                return false
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func waitForCleanExit(
        _ process: Process,
        scenario: ProcessRecoveryScenario
    ) throws {
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        guard !process.isRunning else {
            let diagnostics = terminateAndCollect(process)
            throw ProcessRecoveryError.workerTimedOut(
                "\(scenario.rawValue): \(diagnostics)"
            )
        }
        process.waitUntilExit()
        let diagnostics = collectOutput(process)
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw ProcessRecoveryError.workerFailed(
                "\(scenario.rawValue): \(diagnostics)"
            )
        }
    }

    private func terminateAndCollect(_ process: Process) -> String {
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return collectOutput(process)
    }

    private func collectOutput(_ process: Process) -> String {
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

private enum ProcessRecoveryEnvironment {
    static let worker = "HOSTWRIGHT_LIFECYCLE_PROCESS_RECOVERY_WORKER"
    static let directory = "HOSTWRIGHT_LIFECYCLE_PROCESS_RECOVERY_DIRECTORY"
    static let scenario = "HOSTWRIGHT_LIFECYCLE_PROCESS_RECOVERY_SCENARIO"
    static let stage = "HOSTWRIGHT_LIFECYCLE_PROCESS_RECOVERY_STAGE"
}

private enum ProcessRecoveryScenario: String, CaseIterable, Sendable {
    case intentPending = "intent-pending"
    case effectSatisfied = "effect-satisfied"
    case effectPartial = "effect-partial"
    case effectAmbiguous = "effect-ambiguous"
    case verifiedCheckpoint = "verified-checkpoint"
    case compensationCheckpoint = "compensation-checkpoint"
}

private enum ProcessRecoveryStage: String, Sendable {
    case kill
    case resume
}

private enum ProcessRecoveryError: Error {
    case invalidFoundation
    case testBundleUnavailable
    case workerDidNotReachBoundary(String)
    case workerTimedOut(String)
    case workerFailed(String)
    case ledgerFailure
}

private struct ProcessRecoveryFoundation: Sendable {
    static let ownerFileName = ".hostwright-lifecycle-process-owned"
    static let readyFileName = "worker.ready"
    static let databaseFileName = "state.sqlite"
    static let ledgerFileName = "runtime-effects.log"

    let directory: URL
    let scenario: ProcessRecoveryScenario
    let stage: ProcessRecoveryStage
    let store: SQLiteStateStore
    let plan: LifecyclePlan
    let operationID: String
    let groupID: String
    let fence: String

    var ownerURL: URL {
        directory.appendingPathComponent(Self.ownerFileName)
    }

    var readyURL: URL {
        directory.appendingPathComponent(Self.readyFileName)
    }

    var ledgerURL: URL {
        directory.appendingPathComponent(Self.ledgerFileName)
    }

    static func make(
        scenario: ProcessRecoveryScenario
    ) throws -> ProcessRecoveryFoundation {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-lifecycle-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let owner = directory.appendingPathComponent(ownerFileName)
        try Data((UUID().uuidString.lowercased() + "\n").utf8).write(
            to: owner,
            options: .withoutOverwriting
        )
        XCTAssertEqual(chmod(owner.path, 0o600), 0)
        let foundation = try build(
            directory: directory,
            scenario: scenario,
            stage: .kill
        )
        try foundation.store.migrate()
        return foundation
    }

    static func load(
        environment: [String: String]
    ) throws -> ProcessRecoveryFoundation {
        guard let directoryPath = environment[ProcessRecoveryEnvironment.directory],
              let scenarioValue = environment[ProcessRecoveryEnvironment.scenario],
              let scenario = ProcessRecoveryScenario(rawValue: scenarioValue),
              let stageValue = environment[ProcessRecoveryEnvironment.stage],
              let stage = ProcessRecoveryStage(rawValue: stageValue) else {
            throw ProcessRecoveryError.invalidFoundation
        }
        let directory = URL(fileURLWithPath: directoryPath)
        guard validOwnedDirectory(directory) else {
            throw ProcessRecoveryError.invalidFoundation
        }
        return try build(
            directory: directory,
            scenario: scenario,
            stage: stage
        )
    }

    static func build(
        directory: URL,
        scenario: ProcessRecoveryScenario,
        stage: ProcessRecoveryStage
    ) throws -> ProcessRecoveryFoundation {
        let identities = ProcessRecoveryIdentity(scenario: scenario)
        let primary = try LifecyclePlanNode(
            key: "create-primary",
            action: .create,
            serviceName: "primary",
            resourceIdentifier: "hostwright-process-\(scenario.rawValue)",
            resourceUUID: identities.resourceUUID,
            resourceGeneration: 1,
            fencingToken: identities.fence,
            compensation: LifecycleCompensation(action: .delete),
            desiredSpecificationJSONRedacted:
                #"{"image":"local/process-recovery@sha256:abc"}"#
        )
        var nodes = [primary]
        if scenario == .verifiedCheckpoint {
            nodes.append(
                try LifecyclePlanNode(
                    key: "start-primary",
                    action: .start,
                    serviceName: "primary",
                    resourceIdentifier:
                        "hostwright-process-\(scenario.rawValue)",
                    resourceUUID: identities.resourceUUID,
                    resourceGeneration: 1,
                    fencingToken: identities.fence,
                    dependencies: [primary.key],
                    compensation: LifecycleCompensation(action: .stop)
                )
            )
        }
        let plan = try LifecyclePlan(
            command: .up,
            projectID: "project-\(scenario.rawValue)",
            projectName: "process-recovery",
            projectResourceUUID: identities.projectUUID,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            observationSHA256: String(repeating: "b", count: 64),
            capabilitySHA256: String(repeating: "c", count: 64),
            nodes: nodes
        )
        return ProcessRecoveryFoundation(
            directory: directory,
            scenario: scenario,
            stage: stage,
            store: SQLiteStateStore(
                path: directory.appendingPathComponent(databaseFileName).path
            ),
            plan: plan,
            operationID: identities.operationID,
            groupID: identities.groupID,
            fence: identities.fence
        )
    }

    func runWorker() async throws {
        guard Self.validOwnedDirectory(directory),
              try store.schemaVersion() == 7 else {
            throw ProcessRecoveryError.invalidFoundation
        }
        let result = try await LifecycleSagaExecutor(
            store: store,
            effects: ProcessRecoveryEffects(foundation: self),
            validator: ProcessRecoveryValidator(),
            clock: ProcessRecoveryClock(stage: stage)
        ).execute(
            plan: plan,
            operationID: operationID,
            groupID: groupID,
            fencingToken: fence,
            lockOwner: "lifecycle-process-\(stage.rawValue)"
        )
        switch scenario {
        case .effectPartial, .compensationCheckpoint:
            guard result.status == .compensated else {
                throw ProcessRecoveryError.workerFailed(
                    "Expected compensation, got \(result.status.rawValue)."
                )
            }
        case .effectAmbiguous:
            guard result.status == .safeHold else {
                throw ProcessRecoveryError.workerFailed(
                    "Expected safe hold, got \(result.status.rawValue)."
                )
            }
        default:
            guard result.status == .succeeded else {
                throw ProcessRecoveryError.workerFailed(
                    "Expected success, got \(result.status.rawValue)."
                )
            }
        }
    }

    func publishReady(boundary: String) throws {
        let descriptor = Darwin.open(
            readyURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProcessRecoveryError.invalidFoundation
        }
        defer { Darwin.close(descriptor) }
        let bytes = Array("ready:\(scenario.rawValue):\(boundary)\n".utf8)
        guard Self.writeAll(bytes, to: descriptor),
              fsync(descriptor) == 0 else {
            throw ProcessRecoveryError.invalidFoundation
        }
    }

    func remove() throws {
        guard Self.validOwnedDirectory(directory) else {
            throw ProcessRecoveryError.invalidFoundation
        }
        try FileManager.default.removeItem(at: directory)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ProcessRecoveryError.invalidFoundation
        }
    }

    static func validOwnedDirectory(_ directory: URL) -> Bool {
        let normalized = URL(
            fileURLWithPath: NSString(string: directory.path).standardizingPath
        )
        guard directory.path == normalized.path,
              directory.lastPathComponent.hasPrefix(
                  "hostwright-lifecycle-process-"
              ) else {
            return false
        }
        var directoryMetadata = stat()
        var ownerMetadata = stat()
        let owner = directory.appendingPathComponent(ownerFileName)
        guard lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              lstat(owner.path, &ownerMetadata) == 0,
              ownerMetadata.st_mode & S_IFMT == S_IFREG,
              ownerMetadata.st_uid == geteuid(),
              ownerMetadata.st_nlink == 1,
              ownerMetadata.st_mode & 0o7777 == 0o600,
              let value = try? String(contentsOf: owner, encoding: .utf8),
              value.range(
                  of:
                    "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\n$",
                  options: .regularExpression
              ) != nil else {
            return false
        }
        return true
    }

    static func validReadyMarker(_ url: URL) -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600,
              let value = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return value.range(
            of:
                "^ready:[a-z-]+:(intent-effect-pending|effect-before-observation|verified-checkpoint|compensation-checkpoint)\\n$",
            options: .regularExpression
        ) != nil
    }

    static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}

private struct ProcessRecoveryIdentity {
    let operationID: String
    let groupID: String
    let fence: String
    let projectUUID: String
    let resourceUUID: String

    init(scenario: ProcessRecoveryScenario) {
        operationID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-process-operation",
            identifier: scenario.rawValue
        )
        groupID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-process-group",
            identifier: scenario.rawValue
        )
        fence = HostwrightResourceUUID.legacy(
            kind: "lifecycle-process-fence",
            identifier: scenario.rawValue
        )
        projectUUID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-process-project",
            identifier: scenario.rawValue
        )
        resourceUUID = HostwrightResourceUUID.legacy(
            kind: "lifecycle-process-resource",
            identifier: scenario.rawValue
        )
    }
}

private struct ProcessRecoveryClock: LifecycleSagaClock {
    let stage: ProcessRecoveryStage

    func now() -> String {
        switch stage {
        case .kill:
            "2026-07-23T00:00:00Z"
        case .resume:
            "2026-07-23T00:20:00Z"
        }
    }
}

private struct ProcessRecoveryValidator: LifecycleSagaContextValidating {
    func validate(
        plan: LifecyclePlan,
        node: LifecyclePlanNode,
        expectedFencingToken: String
    ) async -> LifecycleSagaValidation {
        LifecycleSagaValidation(
            providerID: plan.providerID,
            providerGeneration: plan.providerGeneration,
            capabilitySHA256: plan.capabilitySHA256,
            projectResourceUUID: plan.projectResourceUUID,
            projectGeneration: plan.projectGeneration,
            fencingToken: expectedFencingToken,
            ownershipVerified: true
        )
    }
}

private struct ProcessRecoveryEffects: LifecycleSagaEffects {
    let foundation: ProcessRecoveryFoundation

    func apply(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaApplyOutcome {
        do {
            if foundation.stage == .kill {
                switch foundation.scenario {
                case .intentPending where node.key == "create-primary":
                    try requireCheckpoint(
                        "\(node.key):effect-pending",
                        context: context
                    )
                    try stop(boundary: "intent-effect-pending")
                case .effectSatisfied where node.key == "create-primary":
                    try ProcessRecoveryLedger.append(
                        .applySatisfied,
                        node: node.key,
                        to: foundation.ledgerURL
                    )
                    try stop(boundary: "effect-before-observation")
                case .effectPartial where node.key == "create-primary":
                    try ProcessRecoveryLedger.append(
                        .applyPartial,
                        node: node.key,
                        to: foundation.ledgerURL
                    )
                    try stop(boundary: "effect-before-observation")
                case .effectAmbiguous where node.key == "create-primary":
                    try ProcessRecoveryLedger.append(
                        .applyAmbiguous,
                        node: node.key,
                        to: foundation.ledgerURL
                    )
                    try stop(boundary: "effect-before-observation")
                case .verifiedCheckpoint where node.key == "start-primary":
                    let steps = try foundation.store.operationGroupSteps.load(
                        groupID: context.groupID
                    )
                    guard steps.contains(where: {
                        $0.stepKey == "create-primary" &&
                            $0.status == .succeeded
                    }) else {
                        throw ProcessRecoveryError.invalidFoundation
                    }
                    try stop(boundary: "verified-checkpoint")
                default:
                    break
                }
            }
            let event: ProcessRecoveryLedgerEvent =
                foundation.scenario == .effectPartial ||
                foundation.scenario == .compensationCheckpoint
                ? .applyPartial
                : foundation.scenario == .effectAmbiguous
                    ? .applyAmbiguous
                    : .applySatisfied
            try ProcessRecoveryLedger.append(
                event,
                node: node.key,
                to: foundation.ledgerURL
            )
            return .accepted
        } catch {
            return .failed(failure(context: context))
        }
    }

    func observe(
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaObservation {
        guard let ledger = try? ProcessRecoveryLedger.read(
            foundation.ledgerURL
        ) else {
            return .ambiguous(
                LifecycleNodeVerification(
                    summaryRedacted: "runtime effect ledger could not be read"
                )
            )
        }
        let verification = LifecycleNodeVerification(
            summaryRedacted: "persisted runtime effect ledger observed"
        )
        if node.action == .delete {
            switch ledger.state(of: node.key) {
            case .absent:
                return .satisfied(verification)
            case .satisfied, .partial:
                return .noEffect(verification)
            case .ambiguous:
                return .ambiguous(verification)
            }
        }
        switch ledger.state(of: node.key) {
        case .absent:
            return .noEffect(verification)
        case .satisfied:
            return .satisfied(verification)
        case .partial:
            return .effectPresent(verification)
        case .ambiguous:
            return .ambiguous(verification)
        }
    }

    func compensate(
        compensation: LifecycleCompensation,
        node: LifecyclePlanNode,
        context: LifecycleSagaContext
    ) async -> LifecycleSagaCompensationOutcome {
        do {
            if foundation.stage == .kill,
               foundation.scenario == .compensationCheckpoint {
                try requireCheckpoint(
                    "\(node.key):compensation-pending",
                    context: context
                )
                try stop(boundary: "compensation-checkpoint")
            }
            try ProcessRecoveryLedger.append(
                .compensate,
                node: node.key,
                to: foundation.ledgerURL
            )
            return .compensated(
                LifecycleNodeVerification(
                    summaryRedacted: "persisted runtime effect removed"
                )
            )
        } catch {
            return .failed(failure(context: context))
        }
    }

    private func requireCheckpoint(
        _ checkpoint: String,
        context: LifecycleSagaContext
    ) throws {
        let group = try foundation.store.operationGroups.load(
            id: context.groupID
        )
        guard group?.status == .active,
              group?.checkpoint == checkpoint,
              group?.planHash == context.plan.planSHA256,
              group?.fencingToken == context.fencingToken else {
            throw ProcessRecoveryError.invalidFoundation
        }
    }

    private func stop(boundary: String) throws -> Never {
        try foundation.publishReady(boundary: boundary)
        while true {
            _ = Darwin.pause()
        }
    }

    private func failure(
        context: LifecycleSagaContext
    ) -> RuntimeNormalizedFailure {
        RuntimeNormalizedFailure(
            category: .invalidResponse,
            retryDisposition: .never,
            recoveryDisposition: .none,
            providerID: context.plan.providerID.rawValue,
            providerVersion: "process-recovery-test",
            operationID: context.operationID,
            diagnostic: "The controlled process recovery ledger failed.",
            guidance: "Inspect the process recovery test workspace."
        )
    }
}

private enum ProcessRecoveryLedgerEvent: String {
    case applySatisfied = "apply-satisfied"
    case applyPartial = "apply-partial"
    case applyAmbiguous = "apply-ambiguous"
    case compensate
}

private enum ProcessRecoveryLedgerState: Equatable {
    case absent
    case satisfied
    case partial
    case ambiguous
}

private struct ProcessRecoveryLedger {
    let entries: [(event: ProcessRecoveryLedgerEvent, node: String)]

    static func append(
        _ event: ProcessRecoveryLedgerEvent,
        node: String,
        to url: URL
    ) throws {
        guard node.range(
            of: "^[a-z0-9](?:[a-z0-9-]{0,126}[a-z0-9])?$",
            options: .regularExpression
        ) != nil else {
            throw ProcessRecoveryError.ledgerFailure
        }
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ProcessRecoveryError.ledgerFailure
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600 else {
            throw ProcessRecoveryError.ledgerFailure
        }
        let bytes = Array("\(event.rawValue)|\(node)\n".utf8)
        guard ProcessRecoveryFoundation.writeAll(bytes, to: descriptor),
              fsync(descriptor) == 0 else {
            throw ProcessRecoveryError.ledgerFailure
        }
    }

    static func read(_ url: URL) throws -> ProcessRecoveryLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ProcessRecoveryLedger(entries: [])
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == 0o600 else {
            throw ProcessRecoveryError.ledgerFailure
        }
        let value = try String(contentsOf: url, encoding: .utf8)
        let lines = value.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [(ProcessRecoveryLedgerEvent, String)] = []
        for line in lines {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let event = ProcessRecoveryLedgerEvent(
                      rawValue: String(fields[0])
                  ) else {
                throw ProcessRecoveryError.ledgerFailure
            }
            let node = String(fields[1])
            guard node.range(
                of: "^[a-z0-9](?:[a-z0-9-]{0,126}[a-z0-9])?$",
                options: .regularExpression
            ) != nil else {
                throw ProcessRecoveryError.ledgerFailure
            }
            entries.append((event, node))
        }
        return ProcessRecoveryLedger(entries: entries)
    }

    func count(event: ProcessRecoveryLedgerEvent, node: String) -> Int {
        entries.filter { $0.event == event && $0.node == node }.count
    }

    func state(of node: String) -> ProcessRecoveryLedgerState {
        var state = ProcessRecoveryLedgerState.absent
        for entry in entries where entry.node == node {
            switch entry.event {
            case .applySatisfied:
                state = .satisfied
            case .applyPartial:
                state = .partial
            case .applyAmbiguous:
                state = .ambiguous
            case .compensate:
                state = .absent
            }
        }
        return state
    }
}
