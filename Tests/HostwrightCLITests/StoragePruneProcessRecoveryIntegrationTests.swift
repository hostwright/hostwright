import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightState
import HostwrightStorage
import XCTest
@testable import HostwrightCLI

final class StoragePruneProcessRecoveryIntegrationTests:
    XCTestCase
{
    func testPruneRecoversAfterSIGKILLAroundProviderDelete()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        if environment[PruneProcessEnvironment.worker] == "1" {
            let foundation = try PruneProcessFoundation.load(
                environment: environment
            )
            try await foundation.runWorker()
            return
        }

        for boundary in PruneProcessBoundary.allCases {
            let foundation = try await PruneProcessFoundation.make(
                boundary: boundary
            )
            do {
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
                try waitForCleanExit(
                    resumed,
                    boundary: boundary
                )
                try foundation.assertRecovered()
                try foundation.remove()
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: foundation.directory.path
                    )
                )
            } catch {
                if FileManager.default.fileExists(
                    atPath: foundation.directory.path
                ) {
                    try? foundation.remove()
                }
                throw error
            }
        }
    }

    private func launchWorker(
        foundation: PruneProcessFoundation,
        stage: PruneProcessStage
    ) throws -> Process {
        let bundle = Bundle(for: Self.self).bundleURL
        guard bundle.pathExtension == "xctest",
              FileManager.default.fileExists(atPath: bundle.path) else {
            throw PruneProcessError.testBundleUnavailable
        }
        let selector =
            "HostwrightCLITests.StoragePruneProcessRecoveryIntegrationTests/testPruneRecoversAfterSIGKILLAroundProviderDelete"
        let process = Process()
        let parentEnvironment =
            ProcessInfo.processInfo.environment
        let sanitizerRuntime =
            parentEnvironment["DYLD_INSERT_LIBRARIES"] ??
                parentEnvironment[
                    "HOSTWRIGHT_TEST_DYLD_INSERT_LIBRARIES"
                ]
        if sanitizerRuntime != nil {
            let developerDirectory =
                parentEnvironment["DEVELOPER_DIR"] ??
                    "/Applications/Xcode.app/Contents/Developer"
            let xctest = URL(fileURLWithPath: developerDirectory)
                .appendingPathComponent("usr/bin/xctest")
            if FileManager.default.fileExists(atPath: xctest.path) {
                process.executableURL = xctest
                process.arguments = [
                    "-XCTest", selector, bundle.path,
                ]
            } else {
                process.executableURL =
                    URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = [
                    "xctest", "-XCTest", selector, bundle.path,
                ]
            }
        } else {
            process.executableURL =
                URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "xctest", "-XCTest", selector, bundle.path,
            ]
        }
        var childEnvironment = [
            "HOME": NSHomeDirectory(),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            PruneProcessEnvironment.worker: "1",
            PruneProcessEnvironment.directory:
                foundation.directory.path,
            PruneProcessEnvironment.boundary:
                foundation.boundary.rawValue,
            PruneProcessEnvironment.stage: stage.rawValue,
        ]
        for key in [
            "DYLD_INSERT_LIBRARIES",
            "ASAN_OPTIONS",
            "TSAN_OPTIONS",
            "UBSAN_OPTIONS",
            "MallocNanoZone",
        ] {
            if let value = parentEnvironment[key] {
                childEnvironment[key] = value
            }
        }
        if childEnvironment["DYLD_INSERT_LIBRARIES"] == nil,
           let sanitizerRuntime {
            childEnvironment["DYLD_INSERT_LIBRARIES"] =
                sanitizerRuntime
        }
        process.environment = childEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func assertKillBoundary(
        foundation: PruneProcessFoundation,
        process: Process
    ) throws {
        guard waitForReadyMarker(
            foundation.readyURL,
            process: process
        ) else {
            let diagnostics = terminateAndCollect(process)
            throw PruneProcessError.workerDidNotReachBoundary(
                diagnostics
            )
        }
        let group = try XCTUnwrap(
            foundation.store.operationGroups.load(
                id: foundation.groupID
            )
        )
        XCTAssertEqual(group.status, .active)
        XCTAssertEqual(group.planHash, foundation.planSHA256)
        XCTAssertEqual(
            group.checkpoint,
            "provider-effect-requested"
        )
        XCTAssertTrue(
            group.intentJSONRedacted.contains(
                foundation.volumeID
            )
        )
        XCTAssertEqual(
            Darwin.kill(process.processIdentifier, SIGKILL),
            0
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        errno = 0
        XCTAssertEqual(
            Darwin.kill(process.processIdentifier, 0),
            -1
        )
        XCTAssertEqual(errno, ESRCH)
        let provider = try LocalStorageProvider(
            rootURL: foundation.providerRoot,
            totalCapacityBytes: PruneProcessFoundation.capacity
        )
        switch foundation.boundary {
        case .beforeDeleteEffect:
            XCTAssertEqual(
                try provider.list().volumes.map(\.volumeID),
                [foundation.volumeID]
            )
        case .afterDeleteEffect:
            XCTAssertTrue(try provider.list().volumes.isEmpty)
        }
        try FileManager.default.removeItem(
            at: foundation.readyURL
        )
    }

    private func waitForReadyMarker(
        _ url: URL,
        process: Process
    ) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if (try? Data(contentsOf: url)) ==
                Data("ready\n".utf8) {
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
        boundary: PruneProcessBoundary
    ) throws {
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        guard !process.isRunning else {
            let diagnostics = terminateAndCollect(process)
            throw PruneProcessError.workerTimedOut(
                "\(boundary.rawValue): \(diagnostics)"
            )
        }
        process.waitUntilExit()
        let diagnostics = collectOutput(process)
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw PruneProcessError.workerFailed(
                "\(boundary.rawValue): \(diagnostics)"
            )
        }
    }

    private func terminateAndCollect(
        _ process: Process
    ) -> String {
        if process.isRunning {
            _ = Darwin.kill(
                process.processIdentifier,
                SIGKILL
            )
        }
        process.waitUntilExit()
        return collectOutput(process)
    }

    private func collectOutput(_ process: Process) -> String {
        let standardOutput =
            (process.standardOutput as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ??
                Data()
        let standardError =
            (process.standardError as? Pipe)?
                .fileHandleForReading.readDataToEndOfFile() ??
                Data()
        return [
            String(decoding: standardOutput, as: UTF8.self),
            String(decoding: standardError, as: UTF8.self),
        ].joined(separator: "\n")
    }
}

private enum PruneProcessEnvironment {
    static let worker =
        "HOSTWRIGHT_STORAGE_PRUNE_PROCESS_WORKER"
    static let directory =
        "HOSTWRIGHT_STORAGE_PRUNE_PROCESS_DIRECTORY"
    static let boundary =
        "HOSTWRIGHT_STORAGE_PRUNE_PROCESS_BOUNDARY"
    static let stage =
        "HOSTWRIGHT_STORAGE_PRUNE_PROCESS_STAGE"
}

private enum PruneProcessBoundary:
    String,
    CaseIterable,
    Sendable
{
    case beforeDeleteEffect = "before-delete-effect"
    case afterDeleteEffect = "after-delete-effect"

    var faultPoint: LocalStorageProviderFaultPoint {
        switch self {
        case .beforeDeleteEffect:
            .afterIntentPersisted
        case .afterDeleteEffect:
            .afterEffectPersisted
        }
    }
}

private enum PruneProcessStage: String, Sendable {
    case kill
    case resume
}

private enum PruneProcessError: Error {
    case invalidFoundation
    case testBundleUnavailable
    case workerDidNotReachBoundary(String)
    case workerTimedOut(String)
    case workerFailed(String)
    case fileIO
}

private struct PruneProcessFoundation: Sendable {
    static let capacity: Int64 = 16 * 1_024 * 1_024
    static let now: Int64 = 2_000_000_000_000
    static let ownerFileName =
        ".hostwright-storage-prune-process-owned"
    static let stateFileName = "state.sqlite3"
    static let planFileName = "plan.sha256"
    static let readyFileName = "worker.ready"
    static let effectFileName = "delete-effects.log"
    static let unmanagedDirectoryName =
        "unmanaged-sentinel"

    let directory: URL
    let boundary: PruneProcessBoundary
    let stage: PruneProcessStage
    let planSHA256: String
    let volumeID: String

    var providerRoot: URL {
        directory.appendingPathComponent(
            "provider",
            isDirectory: true
        )
    }

    var stateURL: URL {
        directory.appendingPathComponent(
            Self.stateFileName,
            isDirectory: false
        )
    }

    var planURL: URL {
        directory.appendingPathComponent(
            Self.planFileName,
            isDirectory: false
        )
    }

    var readyURL: URL {
        directory.appendingPathComponent(
            Self.readyFileName,
            isDirectory: false
        )
    }

    var effectURL: URL {
        directory.appendingPathComponent(
            Self.effectFileName,
            isDirectory: false
        )
    }

    var unmanagedURL: URL {
        providerRoot
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(
                Self.unmanagedDirectoryName,
                isDirectory: true
            )
    }

    var store: SQLiteStateStore {
        SQLiteStateStore(path: stateURL.path)
    }

    var groupID: String {
        HostwrightResourceUUID.legacy(
            kind: "storage-prune-operation",
            identifier: planSHA256
        )
    }

    static func make(
        boundary: PruneProcessBoundary
    ) async throws -> PruneProcessFoundation {
        let rawTemporary =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporary =
            rawTemporary.hasPrefix("/var/")
                ? "/private\(rawTemporary)"
                : rawTemporary
        let directory = URL(
            fileURLWithPath: canonicalTemporary,
            isDirectory: true
        ).appendingPathComponent(
            "hostwright-storage-prune-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let ownerURL = directory.appendingPathComponent(
            ownerFileName,
            isDirectory: false
        )
        try Data(
            (UUID().uuidString.lowercased() + "\n").utf8
        ).write(to: ownerURL, options: .withoutOverwriting)
        guard chmod(ownerURL.path, 0o600) == 0 else {
            throw PruneProcessError.fileIO
        }

        let index =
            boundary == .beforeDeleteEffect ? "1" : "2"
        let volumeID =
            "31000000-0000-4000-8000-00000000000\(index)"
        let foundation = PruneProcessFoundation(
            directory: directory,
            boundary: boundary,
            stage: .kill,
            planSHA256: String(repeating: "0", count: 64),
            volumeID: volumeID
        )
        let provider = try LocalStorageProvider(
            rootURL: foundation.providerRoot,
            totalCapacityBytes: capacity
        )
        let client = try StorageProviderClient(
            provider: provider
        )
        let projectID = "prune-process-\(index)"
        let projectUUID = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: projectID
            )
        )!
        let fence = UUID(
            uuidString:
                "32000000-0000-4000-8000-00000000000\(index)"
        )!
        let providerContext = StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: 1,
            resourceUUID: UUID(uuidString: volumeID)!,
            resourceGeneration: 1,
            fencingToken: fence
        )
        let _: LocalStorageMutationResult =
            try await client.invoke(
                operation: .create,
                mutationContext: providerContext,
                idempotencyKey: sha256(
                    "create:\(volumeID)"
                ),
                payload: LocalStorageCreatePayload(
                    name: "prune-process-\(index)",
                    capacityBytes: 1_048_576,
                    retention: .deleteWhenUnused
                ),
                result: LocalStorageMutationResult.self
            )
        try FileManager.default.createDirectory(
            at: foundation.unmanagedURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sentinel = foundation.unmanagedURL
            .appendingPathComponent(
                "preserve.txt",
                isDirectory: false
            )
        try Data("unmanaged-sentinel\n".utf8).write(
            to: sentinel,
            options: .withoutOverwriting
        )
        guard chmod(sentinel.path, 0o600) == 0 else {
            throw PruneProcessError.fileIO
        }

        let store = foundation.store
        try store.migrate()
        let repository = StorageStateRepository(store: store)
        let initialGroupID =
            "33000000-0000-4000-8000-00000000000\(index)"
        let createdAt = timestamp(now - 3 * 60 * 60 * 1_000)
        let initialGroup = OperationGroupRecord(
            id: initialGroupID,
            operationID: initialGroupID,
            groupKind: "storage-volume",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "create",
            status: .active,
            groupIdempotencyKey: sha256(
                "state:\(volumeID)"
            ),
            planHash: String(repeating: "a", count: 64),
            checkpoint: "provider-observed",
            lockOwner: "test",
            lockExpiresAt: "2035-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: createdAt,
            updatedAt: createdAt,
            metadataJSONRedacted: "{}",
            fencingToken: fence.uuidString.lowercased(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        guard try store.operationGroups.acquire(
            initialGroup,
            currentTimestamp: createdAt
        ).acquired != nil else {
            throw PruneProcessError.invalidFoundation
        }
        let volume = StorageStateVolumeRecord(
            id: volumeID,
            projectID: projectID,
            name: "prune-process-\(index)",
            providerID:
                LocalStorageProviderContract.providerID,
            providerVolumeID: volumeID,
            topologyNodeID: "local-apple-silicon",
            generation: 1,
            fencingToken: fence.uuidString.lowercased(),
            capacityBytes: 1_048_576,
            lifecycleState: .deleted,
            reclaimPolicy: .delete,
            accessMode: .readWriteOnce,
            operationGroupID: initialGroupID,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try repository.saveVolume(volume)
        try store.operationGroups.finish(
            groupID: initialGroupID,
            status: .succeeded,
            checkpoint: "state-committed",
            manualRecoveryHintRedacted: "",
            updatedAt: createdAt,
            metadataJSONRedacted: "{}"
        )
        try repository.saveOrphan(
            StorageStateOrphanRecord(
                id:
                    "34000000-0000-4000-8000-00000000000\(index)",
                providerID:
                    LocalStorageProviderContract.providerID,
                resourceKind: .volume,
                providerResourceIDHash:
                    orphanResourceHash(volumeID),
                ownershipProofSHA256: nil,
                generation: 1,
                fencingToken: fence.uuidString.lowercased(),
                lifecycleState: .discovered,
                operationGroupID: initialGroupID,
                discoveredAt: createdAt,
                resolvedAt: nil
            )
        )

        let previewProvider = try LocalStorageProvider(
            rootURL: foundation.providerRoot,
            totalCapacityBytes: capacity
        )
        let previewClient = try StorageProviderClient(
            provider: previewProvider
        )
        let coordinator = foundation.coordinator(
            provider: previewProvider
        )
        let dryRun = try await coordinator.prune(
            confirmation: StorageDestructiveCLIOptions(
                dryRun: true,
                confirmationPlanSHA256: nil
            ),
            client: previewClient
        )
        let plan = try planSHA256(dryRun)
        try Data((plan + "\n").utf8).write(
            to: foundation.planURL,
            options: .withoutOverwriting
        )
        guard chmod(foundation.planURL.path, 0o600) == 0 else {
            throw PruneProcessError.fileIO
        }
        return PruneProcessFoundation(
            directory: directory,
            boundary: boundary,
            stage: .kill,
            planSHA256: plan,
            volumeID: volumeID
        )
    }

    static func load(
        environment: [String: String]
    ) throws -> PruneProcessFoundation {
        guard let directoryPath =
                environment[PruneProcessEnvironment.directory],
              let boundaryText =
                environment[PruneProcessEnvironment.boundary],
              let boundary =
                PruneProcessBoundary(rawValue: boundaryText),
              let stageText =
                environment[PruneProcessEnvironment.stage],
              let stage =
                PruneProcessStage(rawValue: stageText) else {
            throw PruneProcessError.invalidFoundation
        }
        let directory = URL(
            fileURLWithPath: directoryPath,
            isDirectory: true
        )
        guard validOwnedDirectory(directory) else {
            throw PruneProcessError.invalidFoundation
        }
        let planURL = directory.appendingPathComponent(
            planFileName,
            isDirectory: false
        )
        let plan = try String(
            contentsOf: planURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.count == 64,
              plan.allSatisfy({ $0.isHexDigit }) else {
            throw PruneProcessError.invalidFoundation
        }
        let index =
            boundary == .beforeDeleteEffect ? "1" : "2"
        return PruneProcessFoundation(
            directory: directory,
            boundary: boundary,
            stage: stage,
            planSHA256: plan,
            volumeID:
                "31000000-0000-4000-8000-00000000000\(index)"
        )
    }

    func runWorker() async throws {
        guard Self.validOwnedDirectory(directory),
              try store.schemaVersion() ==
                HostwrightContractVersions.stateSchema else {
            throw PruneProcessError.invalidFoundation
        }
        let fault = PruneProcessFault(
            boundary: boundary,
            stage: stage,
            readyURL: readyURL,
            effectURL: effectURL
        )
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: Self.capacity,
            faultInjector: fault.injector
        )
        let client = try StorageProviderClient(
            provider: provider
        )
        _ = try await coordinator(provider: provider).prune(
            confirmation: StorageDestructiveCLIOptions(
                dryRun: false,
                confirmationPlanSHA256: planSHA256
            ),
            client: client
        )
    }

    func coordinator(
        provider: LocalStorageProvider
    ) -> StorageReclaimCommandCoordinator {
        let environment = CLIEnvironment(
            fileExists: {
                FileManager.default.fileExists(atPath: $0)
            },
            readTextFile: {
                try String(
                    contentsOfFile: $0,
                    encoding: .utf8
                )
            },
            writeTextFile: { path, text in
                try text.write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
            },
            executablePath: { _ in nil },
            storageProvider: { provider },
            storageProviderRootURL: { providerRoot },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "macOS test" }
        )
        return StorageReclaimCommandCoordinator(
            options: StorageCLIOptions(
                action: .prune(
                    confirmation:
                        StorageDestructiveCLIOptions(
                            dryRun: true,
                            confirmationPlanSHA256: nil
                        )
                ),
                stateDatabasePath: stateURL.path,
                timeoutSeconds: 30,
                output: .json
            ),
            environment: environment,
            nowUnixMilliseconds: { Self.now }
        )
    }

    func assertRecovered() throws {
        let provider = try LocalStorageProvider(
            rootURL: providerRoot,
            totalCapacityBytes: Self.capacity
        )
        let observation = try provider.list()
        XCTAssertTrue(observation.volumes.isEmpty)
        XCTAssertEqual(
            observation.unmanagedEntries,
            [Self.unmanagedDirectoryName]
        )
        XCTAssertTrue(observation.ambiguousVolumeIDs.isEmpty)
        XCTAssertTrue(observation.pendingRecoveryIDs.isEmpty)
        let sentinel = unmanagedURL.appendingPathComponent(
            "preserve.txt",
            isDirectory: false
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("unmanaged-sentinel\n".utf8)
        )
        var metadata = stat()
        XCTAssertEqual(lstat(sentinel.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o7777, 0o600)

        let repository = StorageStateRepository(store: store)
        let volume = try XCTUnwrap(
            try repository.loadVolume(id: volumeID)
        )
        XCTAssertEqual(volume.lifecycleState, .deleted)
        XCTAssertEqual(volume.generation, 2)
        XCTAssertEqual(volume.operationGroupID, groupID)
        XCTAssertEqual(
            try store.operationGroups.load(id: groupID)?.status,
            .succeeded
        )
        let effects = try String(
            contentsOf: effectURL,
            encoding: .utf8
        ).split(separator: "\n")
        XCTAssertEqual(effects, ["delete-effect"])
    }

    func remove() throws {
        guard Self.validOwnedDirectory(directory) else {
            throw PruneProcessError.invalidFoundation
        }
        try FileManager.default.removeItem(at: directory)
    }

    private static func validOwnedDirectory(_ url: URL) -> Bool {
        let rawTemporary =
            FileManager.default.temporaryDirectory.path
        let canonicalTemporary =
            rawTemporary.hasPrefix("/var/")
                ? "/private\(rawTemporary)"
                : rawTemporary
        guard url.path.hasPrefix(canonicalTemporary + "/"),
              url.lastPathComponent.hasPrefix(
                "hostwright-storage-prune-process-"
              ) else {
            return false
        }
        var directoryMetadata = stat()
        guard lstat(url.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid() else {
            return false
        }
        let ownerURL = url.appendingPathComponent(
            ownerFileName,
            isDirectory: false
        )
        guard let text = try? String(
            contentsOf: ownerURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
              UUID(uuidString: text) != nil else {
            return false
        }
        return true
    }

    private static func planSHA256(
        _ result: CLIRunResult
    ) throws -> String {
        guard let object = try JSONSerialization.jsonObject(
            with: Data(result.standardOutput.utf8)
        ) as? [String: Any],
        let plan = object["planSHA256"] as? String else {
            throw PruneProcessError.invalidFoundation
        }
        return plan
    }

    private static func orphanResourceHash(
        _ volumeID: String
    ) -> String {
        sha256(
            [
                "hostwright.storage.orphan-resource-id.v1",
                LocalStorageProviderContract.providerID,
                "volume",
                volumeID,
            ].joined(separator: "\n")
        )
    }

    private static func timestamp(
        _ milliseconds: Int64
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter.string(
            from: Date(
                timeIntervalSince1970:
                    TimeInterval(milliseconds) / 1_000
            )
        )
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class PruneProcessFault:
    @unchecked Sendable
{
    let boundary: PruneProcessBoundary
    let stage: PruneProcessStage
    let readyURL: URL
    let effectURL: URL

    init(
        boundary: PruneProcessBoundary,
        stage: PruneProcessStage,
        readyURL: URL,
        effectURL: URL
    ) {
        self.boundary = boundary
        self.stage = stage
        self.readyURL = readyURL
        self.effectURL = effectURL
    }

    var injector: LocalStorageProviderFaultInjector {
        LocalStorageProviderFaultInjector { [self] point in
            if point == .afterEffectPersisted,
               stage == .kill ||
                boundary == .beforeDeleteEffect {
                try appendDeleteEffect()
            }
            guard stage == .kill,
                  point == boundary.faultPoint else {
                return
            }
            try writeReadyMarker()
            while true {
                _ = Darwin.pause()
            }
        }
    }

    private func appendDeleteEffect() throws {
        let descriptor = open(
            effectURL.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PruneProcessError.fileIO
        }
        defer { close(descriptor) }
        guard writeAll(
            Data("delete-effect\n".utf8),
            to: descriptor
        ), fsync(descriptor) == 0 else {
            throw PruneProcessError.fileIO
        }
    }

    private func writeReadyMarker() throws {
        let descriptor = open(
            readyURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw PruneProcessError.fileIO
        }
        defer { close(descriptor) }
        guard writeAll(
            Data("ready\n".utf8),
            to: descriptor
        ), fsync(descriptor) == 0 else {
            throw PruneProcessError.fileIO
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32
    ) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                return data.isEmpty
            }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
