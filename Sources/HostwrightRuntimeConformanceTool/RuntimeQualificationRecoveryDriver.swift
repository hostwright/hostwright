import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState

enum RuntimeQualificationRecoveryDriverError: Error, Equatable {
    case invalidSpecification
    case providerPreflightFailed
    case expectedRecoveryDecisionMissing
    case hostwrightExecutableUnavailable
    case hostwrightTerminationFailed
    case stateFoundationFailed
    case runtimeInventoryChanged
    case cleanupFailed
    case invalidEvidence
}

enum RuntimeQualificationRecoveryScenario: String, CaseIterable, Codable, Sendable {
    case cliServiceRestart = "cli-service-restart"
    case helperRestart = "helper-restart"
    case hostwrightTermination = "hostwright-termination"
    case mixedComponentVersions = "mixed-component-versions"
    case checkpointCrash = "checkpoint-crash"
    case staleHelper = "stale-helper"
    case futureProtocolRefusal = "future-protocol-refusal"
    case downgradeRefusal = "downgrade-refusal"
}

struct RuntimeQualificationRecoverySpecification: Equatable, Sendable {
    let providerID: RuntimeProviderID
    let expectedVersion: String
    let scenario: RuntimeQualificationRecoveryScenario
    let localImage: String

    func validated() throws -> Self {
        let versionMatches = switch providerID {
        case .appleContainerCLI: ["1.0.0", "1.1.0"].contains(expectedVersion)
        case .appleContainerization:
            expectedVersion == ContainerizationRuntimeAssetContract.frameworkVersion
        default: false
        }
        let scenarioMatches = switch scenario {
        case .cliServiceRestart: providerID == .appleContainerCLI
        case .helperRestart, .staleHelper: providerID == .appleContainerization
        default: RuntimeProviderID.knownValues.contains(providerID)
        }
        guard versionMatches,
              scenarioMatches,
              !localImage.isEmpty,
              localImage.utf8.count <= 512,
              localImage.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RuntimeQualificationRecoveryDriverError.invalidSpecification
        }
        return self
    }
}

struct RuntimeQualificationRecoveryEvidence: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let scenario: String
    let providerID: String
    let providerVersion: String
    let fixtureImageReference: String
    let fixtureImageDescriptorDigest: String
    let fixtureImageVariantDigest: String
    let fixtureImageArchitecture: String
    let fixtureImageOperatingSystem: String
    let capabilityBeforeSHA256: String
    let capabilityAfterSHA256: String
    let inventoryBeforeSHA256: String
    let inventoryAfterSHA256: String
    let unmanagedInventoryBeforeSHA256: String
    let unmanagedInventoryAfterSHA256: String
    let unmanagedInventoryUnchanged: Bool
    let recoveryDisposition: String
    let recoveryChangeKinds: [String]
    let recoveryFindingReasons: [String]
    let capabilitySnapshotInvalidated: Bool
    let providerGeneration: Int
    let providerMetadataRevisionBefore: Int
    let providerMetadataRevisionAfter: Int
    let contractInput: String
    let durableCheckpointBefore: String?
    let durableCheckpointAfter: String?
    let terminatedExecutable: String?
    let processTreeTerminated: Bool
    let stateSchemaVersion: Int?
    let passedAssertions: Int
    let failedAssertions: Int
    let cleanupComplete: Bool
    let cleanupIdentifiers: [String]

    var unmanagedBeforeSHA256: String { unmanagedInventoryBeforeSHA256 }
    var unmanagedAfterSHA256: String { unmanagedInventoryAfterSHA256 }
}

struct RuntimeQualificationRecoveryExecution: Sendable {
    let fixtureImage: RuntimeLocalImageEvidence
    let evidence: RuntimeQualificationRecoveryEvidence
    let commands: [RuntimeQualificationCommandEvidence]
    let cleanupIdentifiers: [String]
}

enum RuntimeQualificationUnmanagedInventoryDigest {
    private struct Payload: Encodable {
        let containers: [RuntimeInventoryContainer]
        let images: [RuntimeInventoryImage]
        let networks: [RuntimeInventoryNetwork]
        let volumes: [RuntimeInventoryVolume]
    }

    static func sha256(_ inventory: RuntimeInventory) throws -> String {
        let payload = Payload(
            containers: inventory.containers
                .filter { $0.ownership == nil }
                .sorted { $0.runtimeID < $1.runtimeID },
            images: inventory.images
                .filter { $0.ownership == nil }
                .sorted { $0.runtimeID < $1.runtimeID },
            networks: inventory.networks
                .filter { $0.ownership == nil }
                .sorted { $0.runtimeID < $1.runtimeID },
            volumes: inventory.volumes
                .filter { $0.ownership == nil }
                .sorted { $0.runtimeID < $1.runtimeID }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct RuntimeQualificationRecoveryProviderBoundary: Sendable {
    let adapter: any RuntimeAdapter
    let providerID: RuntimeProviderID
    let expectedVersion: String
    let cliExecutablePath: String?
    let helperClient: ContainerizationHelperClient?
    let helperFaultController: RuntimeQualificationHelperFaultController?
    let recorder: RuntimeQualificationCommandRecorder

    static func make(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        recorder: RuntimeQualificationCommandRecorder
    ) async throws -> Self {
        let boundary: Self
        switch providerID {
        case .appleContainerCLI:
            let resolver = RuntimeExecutableResolver()
            guard let executable = try resolver.resolveExecutable(
                named: AppleContainerCommand.executableName
            ) else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            boundary = Self(
                adapter: AppleContainerCLIAdapter(
                    executableResolver: resolver,
                    processRunner: RuntimeQualificationRecordingProcessRunner(recorder: recorder)
                ),
                providerID: providerID,
                expectedVersion: expectedVersion,
                cliExecutablePath: executable.path,
                helperClient: nil,
                helperFaultController: nil,
                recorder: recorder
            )
        case .appleContainerization:
            guard let hostExecutable = Bundle.main.executableURL else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            let configuration = try ContainerizationHelperClientConfiguration.installed(
                hostExecutableURL: hostExecutable
            )
            let registry = RuntimeQualificationHelperProcessRegistry()
            let controller = RuntimeQualificationHelperFaultController(
                registry: registry,
                socketURL: configuration.socketURL
            )
            let client = ContainerizationHelperClient(
                configuration: try ContainerizationHelperClientConfiguration(
                    executableURL: configuration.executableURL,
                    configurationURL: configuration.configurationURL,
                    runtimeDirectoryURL: configuration.runtimeDirectoryURL,
                    launchTimeoutMilliseconds: 5_000,
                    requestTimeoutMilliseconds:
                        RuntimeQualificationHelperTiming.normalRequestTimeoutMilliseconds
                ),
                launcher: registry.launcher(),
                transport: controller.transport()
            )
            boundary = Self(
                adapter: AppleContainerizationRuntimeAdapter(client: client),
                providerID: providerID,
                expectedVersion: expectedVersion,
                cliExecutablePath: nil,
                helperClient: client,
                helperFaultController: controller,
                recorder: recorder
            )
        default:
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        let snapshot = try await boundary.adapter.capabilitySnapshot()
        let version = try await boundary.adapter.runtimeVersion()
        guard snapshot.descriptor.providerID == providerID,
              version == expectedVersion,
              RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).isEmpty else {
            _ = await boundary.shutdown()
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        return boundary
    }

    func restart() async throws {
        switch providerID {
        case .appleContainerCLI:
            guard let cliExecutablePath else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            try await runCLI(executable: cliExecutablePath, arguments: ["system", "stop"])
            try await runCLI(executable: cliExecutablePath, arguments: ["system", "start"])
        case .appleContainerization:
            guard let helperClient, let helperFaultController else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            await helperClient.shutdown()
            guard helperFaultController.verifyFinalShutdown() else {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            await recorder.record(
                arguments: ["hostwright-containerization-helper", "shutdown"],
                exitStatus: 0
            )
            _ = try await adapter.capabilitySnapshot()
            await recorder.record(
                arguments: ["hostwright-containerization-helper", "negotiate"],
                exitStatus: 0
            )
        default:
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
    }

    func shutdown() async -> Bool {
        guard let helperClient else { return true }
        await helperClient.shutdown()
        return helperFaultController?.verifyFinalShutdown() == true
    }

    private func runCLI(executable: String, arguments: [String]) async throws {
        let result = try await SecureSubprocessRunner().runAsync(
            SecureSubprocessRequest(
                executablePath: executable,
                arguments: arguments,
                environment: SecureSubprocessEnvironment.currentUser,
                workingDirectory: "/",
                timeoutMilliseconds: 60_000,
                maximumStandardOutputBytes: 1 * 1_024 * 1_024,
                maximumStandardErrorBytes: 1 * 1_024 * 1_024
            )
        )
        await recorder.record(
            arguments: [executable] + arguments,
            exitStatus: Int(result.exitStatus)
        )
        guard result.exitStatus == 0 else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
    }
}

struct RuntimeQualificationRecoveryStateFoundation: Sendable {
    let directory: URL
    let databaseURL: URL
    let groupID: String
    let fencingToken: String
    let initialCheckpoint: String
    private let markerValue: String

    static func make(
        checkpoint: String,
        parent: URL = FileManager.default.temporaryDirectory
    ) throws -> Self {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let directory = parent.appendingPathComponent(
            "hostwright-phase03-recovery-\(suffix)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = UUID().uuidString.lowercased()
        do {
            let markerURL = directory.appendingPathComponent(".hostwright-phase03-owned")
            try Data((marker + "\n").utf8).write(to: markerURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: markerURL.path
            )
            let groupID = UUID().uuidString.lowercased()
            let fencingToken = UUID().uuidString.lowercased()
            return Self(
                directory: directory,
                databaseURL: directory.appendingPathComponent("state.sqlite"),
                groupID: groupID,
                fencingToken: fencingToken,
                initialCheckpoint: checkpoint,
                markerValue: marker
            )
        } catch {
            let original = error
            do { try FileManager.default.removeItem(at: directory) } catch {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            throw original
        }
    }

    func verifyRecovered(to checkpoint: String) throws -> (before: String, after: String, schema: Int) {
        let store = SQLiteStateStore(path: databaseURL.path)
        guard try store.schemaVersion() == 7,
              let after = try store.operationGroups.load(id: groupID),
              after.status == .succeeded,
              after.checkpoint == checkpoint,
              after.fencingToken == fencingToken,
              after.verificationJSONRedacted.contains("reobserved") else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        return (initialCheckpoint, after.checkpoint, try store.schemaVersion())
    }

    func remove() throws {
        let markerURL = directory.appendingPathComponent(".hostwright-phase03-owned")
        var directoryMetadata = stat()
        var markerMetadata = stat()
        guard NSString(string: directory.path).standardizingPath == directory.path,
              directory.lastPathComponent.hasPrefix("hostwright-phase03-recovery-"),
              lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              lstat(markerURL.path, &markerMetadata) == 0,
              markerMetadata.st_mode & S_IFMT == S_IFREG,
              markerMetadata.st_uid == geteuid(),
              markerMetadata.st_nlink == 1,
              markerMetadata.st_mode & 0o7777 == 0o600,
              try String(contentsOf: markerURL, encoding: .utf8) == markerValue + "\n" else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        try FileManager.default.removeItem(at: directory)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

}

enum RuntimeQualificationRecoveryWorker {
    private static let command = "__phase03-recovery-worker"

    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == command else { return nil }
        guard values.count == 8,
              ["write", "resume"].contains(values[1]) else { return 64 }
        do {
            let databaseURL = try normalizedAbsolute(values[2])
            let signalURL = try normalizedAbsolute(values[7])
            let groupID = values[3]
            let fence = values[4]
            let initialCheckpoint = values[5]
            let resumedCheckpoint = values[6]
            guard HostwrightResourceUUID.isValid(groupID),
                  HostwrightResourceUUID.isValid(fence),
                  validCheckpoint(initialCheckpoint), validCheckpoint(resumedCheckpoint),
                  databaseURL.deletingLastPathComponent()
                    == signalURL.deletingLastPathComponent(),
                  validateOwnedPaths(
                    mode: values[1], databaseURL: databaseURL, signalURL: signalURL
                  ) else { return 64 }
            if values[1] == "write" {
                try writeCheckpoint(
                    databaseURL: databaseURL,
                    groupID: groupID,
                    fencingToken: fence,
                    checkpoint: initialCheckpoint
                )
                try publishSignal(signalURL)
                while true { _ = pause() }
            }
            try resumeCheckpoint(
                databaseURL: databaseURL,
                groupID: groupID,
                fencingToken: fence,
                initialCheckpoint: initialCheckpoint,
                resumedCheckpoint: resumedCheckpoint
            )
            try publishSignal(signalURL)
            return 0
        } catch {
            return 70
        }
    }

    fileprivate static func arguments(
        mode: String,
        foundation: RuntimeQualificationRecoveryStateFoundation,
        resumedCheckpoint: String,
        signalURL: URL
    ) -> [String] {
        [
            command, mode, foundation.databaseURL.path, foundation.groupID,
            foundation.fencingToken, foundation.initialCheckpoint,
            resumedCheckpoint, signalURL.path,
        ]
    }

    private static func writeCheckpoint(
        databaseURL: URL,
        groupID: String,
        fencingToken: String,
        checkpoint: String
    ) throws {
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        guard try store.schemaVersion() == 7 else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let acquired = try store.operationGroups.acquire(OperationGroupRecord(
            id: groupID,
            operationID: UUID().uuidString.lowercased(),
            groupKind: "phase03-recovery",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "recovery-qualification",
            status: .active,
            groupIdempotencyKey: "phase03-recovery-\(groupID)",
            planHash: sha256("phase03-recovery-\(groupID)"),
            checkpoint: checkpoint,
            lockOwner: "hostwright-runtime-conformance",
            lockExpiresAt: "2999-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "Resume from the recorded checkpoint.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: "{\"qualification\":\"phase03\"}",
            fencingToken: fencingToken,
            intentJSONRedacted: "{\"operation\":\"recovery\"}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{\"durable\":true}"
        ))
        guard acquired.acquired?.checkpoint == checkpoint else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
    }

    private static func resumeCheckpoint(
        databaseURL: URL,
        groupID: String,
        fencingToken: String,
        initialCheckpoint: String,
        resumedCheckpoint: String
    ) throws {
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        guard try store.schemaVersion() == 7,
              let before = try store.operationGroups.load(id: groupID),
              before.status == .active,
              before.checkpoint == initialCheckpoint,
              before.fencingToken == fencingToken else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try store.operationGroups.recordCheckpoint(
            groupID: groupID,
            expectedFencingToken: fencingToken,
            checkpoint: resumedCheckpoint,
            verificationJSONRedacted: "{\"reobserved\":true}",
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: groupID,
            status: .succeeded,
            checkpoint: resumedCheckpoint,
            manualRecoveryHintRedacted: "",
            updatedAt: timestamp,
            metadataJSONRedacted: "{\"recovered\":true}"
        )
    }

    private static func publishSignal(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        defer { Darwin.close(descriptor) }
        let bytes = Array("ready\n".utf8)
        guard bytes.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) })
                == bytes.count,
              fsync(descriptor) == 0 else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
    }

    private static func normalizedAbsolute(_ value: String) throws -> URL {
        guard value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 1_024,
              NSString(string: value).standardizingPath == value else {
            throw RuntimeQualificationRecoveryDriverError.invalidSpecification
        }
        return URL(fileURLWithPath: value)
    }

    private static func validateOwnedPaths(
        mode: String,
        databaseURL: URL,
        signalURL: URL
    ) -> Bool {
        let directory = databaseURL.deletingLastPathComponent()
        let markerURL = directory.appendingPathComponent(".hostwright-phase03-owned")
        var directoryMetadata = stat()
        var markerMetadata = stat()
        var databaseMetadata = stat()
        var signalMetadata = stat()
        errno = 0
        let databaseStatus = lstat(databaseURL.path, &databaseMetadata)
        let databaseError = errno
        errno = 0
        let signalStatus = lstat(signalURL.path, &signalMetadata)
        let signalError = errno
        guard directory.lastPathComponent.hasPrefix("hostwright-phase03-recovery-"),
              databaseURL.lastPathComponent == "state.sqlite",
              ["writer.ready", "resumer.ready"].contains(signalURL.lastPathComponent),
              lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              lstat(markerURL.path, &markerMetadata) == 0,
              markerMetadata.st_mode & S_IFMT == S_IFREG,
              markerMetadata.st_uid == geteuid(),
              markerMetadata.st_nlink == 1,
              markerMetadata.st_mode & 0o7777 == 0o600,
              let marker = try? String(contentsOf: markerURL, encoding: .utf8),
              marker.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\n$",
                options: .regularExpression
              ) != nil,
              signalStatus == -1, signalError == ENOENT else { return false }
        if mode == "write" {
            return databaseStatus == -1 && databaseError == ENOENT
        }
        return databaseStatus == 0 &&
            databaseMetadata.st_mode & S_IFMT == S_IFREG &&
            databaseMetadata.st_uid == geteuid() &&
            databaseMetadata.st_nlink == 1 &&
            databaseMetadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
    }

    private static func validCheckpoint(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
            value.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum RuntimeQualificationRecoveryProcessCycle {
    static func run(
        foundation: RuntimeQualificationRecoveryStateFoundation,
        resumedCheckpoint: String,
        recorder: RuntimeQualificationCommandRecorder,
        executableURL: URL? = Bundle.main.executableURL
    ) async throws -> String {
        guard let executable = executableURL else {
            throw RuntimeQualificationRecoveryDriverError.hostwrightExecutableUnavailable
        }
        var metadata = stat()
        guard executable.lastPathComponent == "hostwright-runtime-conformance",
              lstat(executable.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              access(executable.path, X_OK) == 0 else {
            throw RuntimeQualificationRecoveryDriverError.hostwrightExecutableUnavailable
        }
        let writeSignal = foundation.directory.appendingPathComponent("writer.ready")
        let writerObservation = RuntimeQualificationLaunchObservation()
        let writer = Task {
            try await SecureSubprocessRunner().runAsync(
                request(
                    executable: executable,
                    arguments: RuntimeQualificationRecoveryWorker.arguments(
                        mode: "write", foundation: foundation,
                        resumedCheckpoint: resumedCheckpoint, signalURL: writeSignal
                    )
                ),
                onLaunch: writerObservation.record
            )
        }
        guard waitForSignal(writeSignal),
              let writerProcessID = writerObservation.processID,
              getpgid(writerProcessID) == writerProcessID,
              terminate(processGroupID: writerProcessID) else {
            await cancelAndDrain(writer)
            throw RuntimeQualificationRecoveryDriverError.hostwrightTerminationFailed
        }
        let writerResult: SecureSubprocessResult
        do {
            writerResult = try await writer.value
        } catch {
            throw RuntimeQualificationRecoveryDriverError.hostwrightTerminationFailed
        }
        guard writerResult.terminationSignal == SIGKILL,
              processGroupIsAbsent(writerProcessID) else {
            throw RuntimeQualificationRecoveryDriverError.hostwrightTerminationFailed
        }
        try FileManager.default.removeItem(at: writeSignal)
        let resumeSignal = foundation.directory.appendingPathComponent("resumer.ready")
        let resumerResult: SecureSubprocessResult
        do {
            resumerResult = try await SecureSubprocessRunner().runAsync(
                request(
                    executable: executable,
                    arguments: RuntimeQualificationRecoveryWorker.arguments(
                        mode: "resume", foundation: foundation,
                        resumedCheckpoint: resumedCheckpoint, signalURL: resumeSignal
                    )
                )
            )
        } catch {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        guard resumerResult.exitStatus == 0,
              resumerResult.terminationSignal == nil,
              waitForSignal(resumeSignal) else {
            throw RuntimeQualificationRecoveryDriverError.stateFoundationFailed
        }
        await recorder.record(
            arguments: [executable.path, "recovery-worker-write"], exitStatus: -1
        )
        await recorder.record(
            arguments: [executable.path, "recovery-worker-resume"], exitStatus: 0
        )
        return executable.lastPathComponent
    }

    private static func request(
        executable: URL,
        arguments: [String]
    ) -> SecureSubprocessRequest {
        SecureSubprocessRequest(
            executablePath: executable.path,
            arguments: arguments,
            environment: SecureSubprocessEnvironment.currentUser,
            workingDirectory: "/",
            timeoutMilliseconds: 10_000,
            terminationGraceMilliseconds: 100,
            maximumStandardOutputBytes: 64 * 1_024,
            maximumStandardErrorBytes: 64 * 1_024
        )
    }

    private static func waitForSignal(_ url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            var metadata = stat()
            if lstat(url.path, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFREG,
               metadata.st_uid == geteuid(), metadata.st_nlink == 1,
               metadata.st_mode & 0o7777 == 0o600,
               (try? String(contentsOf: url, encoding: .utf8)) == "ready\n" {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private static func cancelAndDrain(
        _ task: Task<SecureSubprocessResult, Error>
    ) async {
        task.cancel()
        _ = try? await task.value
    }

    private static func terminate(processGroupID: pid_t) -> Bool {
        errno = 0
        guard Darwin.kill(-processGroupID, SIGKILL) == 0 || errno == ESRCH else { return false }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if processGroupIsAbsent(processGroupID) { return true }
            usleep(10_000)
        }
        return processGroupIsAbsent(processGroupID)
    }

    private static func processGroupIsAbsent(_ processGroupID: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(-processGroupID, 0) == -1 && errno == ESRCH
    }
}

struct RuntimeQualificationRecoveryDriver {
    private let specification: RuntimeQualificationRecoverySpecification
    let recorder: RuntimeQualificationCommandRecorder

    init(
        specification: RuntimeQualificationRecoverySpecification,
        recorder: RuntimeQualificationCommandRecorder = RuntimeQualificationCommandRecorder()
    ) throws {
        self.specification = try specification.validated()
        self.recorder = recorder
    }

    init(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        scenario: String,
        localImage: String,
        recorder: RuntimeQualificationCommandRecorder = RuntimeQualificationCommandRecorder()
    ) throws {
        guard let scenario = RuntimeQualificationRecoveryScenario(rawValue: scenario) else {
            throw RuntimeQualificationRecoveryDriverError.invalidSpecification
        }
        try self.init(
            specification: RuntimeQualificationRecoverySpecification(
                providerID: providerID,
                expectedVersion: expectedVersion,
                scenario: scenario,
                localImage: localImage
            ),
            recorder: recorder
        )
    }

    func run() async throws -> RuntimeQualificationRecoveryExecution {
        let evidence = try await runEvidence()
        let commands = try await recorder.evidence()
        return RuntimeQualificationRecoveryExecution(
            fixtureImage: RuntimeLocalImageEvidence(
                reference: evidence.fixtureImageReference,
                descriptorDigest: evidence.fixtureImageDescriptorDigest,
                variantDigest: evidence.fixtureImageVariantDigest,
                architecture: evidence.fixtureImageArchitecture,
                operatingSystem: evidence.fixtureImageOperatingSystem
            ),
            evidence: evidence,
            commands: commands,
            cleanupIdentifiers: evidence.cleanupIdentifiers
        )
    }

    func runReport() async throws -> RuntimeQualificationRecoveryReport {
        let execution = try await run()
        return try RuntimeQualificationRecoveryReport.passed(execution: execution)
    }

    private func runEvidence() async throws -> RuntimeQualificationRecoveryEvidence {
        let boundary: RuntimeQualificationRecoveryProviderBoundary
        do {
            boundary = try await .make(
                providerID: specification.providerID,
                expectedVersion: specification.expectedVersion,
                recorder: recorder
            )
        } catch let error as RuntimeQualificationRecoveryDriverError {
            throw error
        } catch {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        var state: RuntimeQualificationRecoveryStateFoundation?
        do {
            let baselineSnapshot = try await boundary.adapter.capabilitySnapshot()
            let image = try await boundary.adapter.localImageEvidence(for: specification.localImage)
            guard image.reference == specification.localImage,
                  Self.isDigest(image.descriptorDigest), Self.isDigest(image.variantDigest) else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            let inventoryBefore = try await boundary.adapter.inventory()
            let unmanagedInventoryBeforeSHA256 = try RuntimeQualificationUnmanagedInventoryDigest.sha256(
                inventoryBefore
            )
            let recordRevision = specification.scenario == .downgradeRefusal
                ? RuntimeProviderMetadataEvidence.currentRevision + 1
                : RuntimeProviderMetadataEvidence.currentRevision
            let record = RuntimeProviderRecoveryRecord(
                persistedProviderBinding: specification.providerID.rawValue,
                providerGeneration: 1,
                providerMetadataRevision: recordRevision,
                fingerprint: RuntimeProviderRecoveryFingerprint(snapshot: baselineSnapshot)
            )

            var evaluationSnapshot = baselineSnapshot
            var contractInput = "live-provider-snapshot"
            var terminatedExecutable: String?
            var processTreeTerminated = false
            var checkpointBefore: String?
            var checkpointAfter: String?
            var stateSchemaVersion: Int?
            switch specification.scenario {
            case .cliServiceRestart, .helperRestart:
                try await boundary.restart()
                evaluationSnapshot = try await boundary.adapter.capabilitySnapshot()
            case .hostwrightTermination, .checkpointCrash:
                let initial = specification.scenario == .hostwrightTermination
                    ? "prepared" : "runtime-effect-recorded"
                let recovered = specification.scenario == .hostwrightTermination
                    ? "recovered-after-hostwright-termination" : "recovered-after-checkpoint-crash"
                let foundation = try RuntimeQualificationRecoveryStateFoundation.make(
                    checkpoint: initial
                )
                state = foundation
                terminatedExecutable = try await RuntimeQualificationRecoveryProcessCycle.run(
                    foundation: foundation,
                    resumedCheckpoint: recovered,
                    recorder: recorder
                )
                processTreeTerminated = true
                evaluationSnapshot = try await boundary.adapter.capabilitySnapshot()
                let checkpoints = try foundation.verifyRecovered(to: recovered)
                checkpointBefore = checkpoints.before
                checkpointAfter = checkpoints.after
                stateSchemaVersion = checkpoints.schema
            case .mixedComponentVersions:
                evaluationSnapshot = Self.mixedSnapshot(from: baselineSnapshot)
                contractInput = "mixed-component-contract-injection-from-live-snapshot"
            case .staleHelper:
                evaluationSnapshot = Self.staleHelperSnapshot(from: baselineSnapshot)
                contractInput = "stale-helper-contract-injection-from-live-snapshot"
            case .futureProtocolRefusal:
                evaluationSnapshot = Self.futureProtocolSnapshot(from: baselineSnapshot)
                contractInput = "future-protocol-contract-injection-from-live-snapshot"
            case .downgradeRefusal:
                contractInput = "future-metadata-revision-against-live-snapshot"
            }

            let evaluation = RuntimeProviderRecoveryEvaluator.evaluate(
                record: record,
                currentSnapshot: evaluationSnapshot,
                metadataSupport: RuntimeProviderMetadataSupport(
                    minimumReadableRevision: RuntimeProviderMetadataEvidence.legacyRevision,
                    currentWritableRevision: RuntimeProviderMetadataEvidence.currentRevision
                )
            )
            try Self.verify(evaluation, for: specification.scenario)
            let inventoryAfter = try await boundary.adapter.inventory()
            let unmanagedInventoryAfterSHA256 = try RuntimeQualificationUnmanagedInventoryDigest.sha256(
                inventoryAfter
            )
            guard inventoryBefore.semanticSHA256 == inventoryAfter.semanticSHA256,
                  unmanagedInventoryBeforeSHA256 == unmanagedInventoryAfterSHA256 else {
                throw RuntimeQualificationRecoveryDriverError.runtimeInventoryChanged
            }
            let cleanupIdentifiers = state.map { [$0.groupID] } ?? []
            try state?.remove()
            state = nil
            guard await boundary.shutdown() else {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            await recorder.record(
                arguments: [
                    "hostwright-runtime-conformance", "recovery",
                    specification.providerID.rawValue, specification.scenario.rawValue,
                ],
                exitStatus: 0
            )
            return RuntimeQualificationRecoveryEvidence(
                schemaVersion: 1,
                scenario: specification.scenario.rawValue,
                providerID: specification.providerID.rawValue,
                providerVersion: specification.expectedVersion,
                fixtureImageReference: image.reference,
                fixtureImageDescriptorDigest: image.descriptorDigest,
                fixtureImageVariantDigest: image.variantDigest,
                fixtureImageArchitecture: image.architecture,
                fixtureImageOperatingSystem: image.operatingSystem,
                capabilityBeforeSHA256: baselineSnapshot.canonicalSHA256,
                capabilityAfterSHA256: evaluationSnapshot.canonicalSHA256,
                inventoryBeforeSHA256: inventoryBefore.semanticSHA256,
                inventoryAfterSHA256: inventoryAfter.semanticSHA256,
                unmanagedInventoryBeforeSHA256: unmanagedInventoryBeforeSHA256,
                unmanagedInventoryAfterSHA256: unmanagedInventoryAfterSHA256,
                unmanagedInventoryUnchanged: true,
                recoveryDisposition: evaluation.disposition.rawValue,
                recoveryChangeKinds: evaluation.changes.map(\.kind.rawValue),
                recoveryFindingReasons: evaluation.findings.map(\.reason.rawValue),
                capabilitySnapshotInvalidated: evaluation.invalidatesCapabilitySnapshot,
                providerGeneration: evaluation.providerGeneration,
                providerMetadataRevisionBefore: record.providerMetadataRevision,
                providerMetadataRevisionAfter: evaluation.nextProviderMetadataRevision,
                contractInput: contractInput,
                durableCheckpointBefore: checkpointBefore,
                durableCheckpointAfter: checkpointAfter,
                terminatedExecutable: terminatedExecutable,
                processTreeTerminated: processTreeTerminated,
                stateSchemaVersion: stateSchemaVersion,
                passedAssertions: 8,
                failedAssertions: 0,
                cleanupComplete: true,
                cleanupIdentifiers: cleanupIdentifiers
            )
        } catch {
            let original = error
            var cleaned = true
            if let state {
                do { try state.remove() } catch { cleaned = false }
            }
            let stopped = await boundary.shutdown()
            guard cleaned, stopped else {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            throw original
        }
    }

}

private extension RuntimeQualificationRecoveryDriver {
    static func verify(
        _ evaluation: RuntimeProviderRecoveryEvaluation,
        for scenario: RuntimeQualificationRecoveryScenario
    ) throws {
        let reasons = Set(evaluation.findings.map(\.reason))
        let valid: Bool = switch scenario {
        case .cliServiceRestart, .helperRestart:
            evaluation.findings.isEmpty &&
                [.resumeFromCheckpoint, .reobserveThenResumeFromCheckpoint]
                    .contains(evaluation.disposition)
        case .hostwrightTermination, .checkpointCrash:
            evaluation.findings.isEmpty && evaluation.disposition == .resumeFromCheckpoint
        case .mixedComponentVersions:
            evaluation.disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(.mixedComponents)
        case .staleHelper:
            evaluation.findings.isEmpty &&
                evaluation.disposition == .reobserveThenResumeFromCheckpoint &&
                evaluation.invalidatesCapabilitySnapshot
        case .futureProtocolRefusal:
            evaluation.disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(.unsupportedFutureProtocol)
        case .downgradeRefusal:
            evaluation.disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(.metadataRevisionTooNew) &&
                evaluation.nextProviderMetadataRevision
                    == RuntimeProviderMetadataEvidence.currentRevision + 1
        }
        guard valid, evaluation.providerGeneration == 1 else {
            throw RuntimeQualificationRecoveryDriverError.expectedRecoveryDecisionMissing
        }
    }

    static func mixedSnapshot(from snapshot: RuntimeCapabilitySnapshot) -> RuntimeCapabilitySnapshot {
        var components = snapshot.descriptor.components
        if snapshot.descriptor.providerID == .appleContainerCLI,
           let index = components.firstIndex(where: {
               $0.identifier == .appleContainerAPIService
           }) {
            let current = components[index]
            components[index] = RuntimeProviderComponent(
                identifier: current.identifier,
                version: current.version == "1.1.0" ? "1.0.0" : "1.1.0",
                build: current.build,
                fingerprint: current.fingerprint
            )
        } else {
            components.append(RuntimeProviderComponent(
                identifier: .appleContainerCLI,
                version: "1.1.0",
                build: "injected",
                fingerprint: sha256("mixed-component")
            ))
        }
        return replacingComponents(in: snapshot, with: components)
    }

    static func staleHelperSnapshot(
        from snapshot: RuntimeCapabilitySnapshot
    ) -> RuntimeCapabilitySnapshot {
        replacingComponent(in: snapshot, identifier: .appleContainerizationHelper) { component in
            RuntimeProviderComponent(
                identifier: component.identifier,
                version: component.version,
                build: component.build,
                fingerprint: sha256("stale-helper")
            )
        }
    }

    static func futureProtocolSnapshot(
        from snapshot: RuntimeCapabilitySnapshot
    ) -> RuntimeCapabilitySnapshot {
        if snapshot.descriptor.providerID == .appleContainerization {
            return replacingComponent(
                in: snapshot,
                identifier: .containerizationHelperProtocolV1
            ) { component in
                RuntimeProviderComponent(
                    identifier: component.identifier,
                    version: "2",
                    build: component.build,
                    fingerprint: component.fingerprint
                )
            }
        }
        var components = snapshot.descriptor.components
        components.append(RuntimeProviderComponent(
            identifier: .containerizationHelperProtocolV1,
            version: "2",
            build: "injected",
            fingerprint: sha256("future-protocol")
        ))
        return replacingComponents(in: snapshot, with: components)
    }

    static func replacingComponent(
        in snapshot: RuntimeCapabilitySnapshot,
        identifier: RuntimeProviderComponentID,
        transform: (RuntimeProviderComponent) -> RuntimeProviderComponent
    ) -> RuntimeCapabilitySnapshot {
        replacingComponents(
            in: snapshot,
            with: snapshot.descriptor.components.map {
                $0.identifier == identifier ? transform($0) : $0
            }
        )
    }

    static func replacingComponents(
        in snapshot: RuntimeCapabilitySnapshot,
        with components: [RuntimeProviderComponent]
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            schemaVersion: snapshot.schemaVersion,
            descriptor: RuntimeProviderDescriptor(
                providerAPIVersion: snapshot.descriptor.providerAPIVersion,
                providerID: snapshot.descriptor.providerID,
                components: components,
                minimumMacOSVersion: snapshot.descriptor.minimumMacOSVersion,
                supportedArchitectures: snapshot.descriptor.supportedArchitectures
            ),
            host: snapshot.host,
            features: snapshot.features
        )
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.range(of: #"\Asha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}
