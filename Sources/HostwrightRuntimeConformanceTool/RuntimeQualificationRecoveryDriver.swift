import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState
import Security

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

enum RuntimeQualificationHelperSignatureVerifier {
    static func sha256(of url: URL) throws -> String {
        let identity: SecureExecutableIdentity
        do {
            identity = try SecureExecutableResolver.verify(
                path: url.path,
                ownershipPolicy: .rootOrCurrentUser
            )
        } catch {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        guard identity.path == url.path,
              url.lastPathComponent == "hostwright-containerization-helper" else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        ) == errSecSuccess,
        let values = signingInformation as? [String: Any],
        matchesExpectedIdentity(
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier: values[kSecCodeInfoIdentifier as String] as? String
        ) else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            ContainerizationHelperPeerIdentityPolicy.expectedDesignatedRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            requirement
        ) == errSecSuccess else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        do {
            try SecureExecutableResolver.verifyUnchanged(identity)
        } catch {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func matchesExpectedIdentity(
        teamIdentifier: String?,
        identifier: String?
    ) -> Bool {
        teamIdentifier == ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier &&
            identifier == "hostwright-containerization-helper"
    }
}

private final class RuntimeQualificationHelperDirectoryLock {
    private var descriptor: Int32

    init(directoryURL: URL) throws {
        descriptor = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
    }

    deinit {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
    }
}

struct RuntimeQualificationInstalledHelperTransition {
    private static let stagingDirectoryName = ".hostwright-phase03-helper-upgrade"

    let installedURL: URL
    let stagedURL: URL
    let priorSHA256: String
    let currentSHA256: String

    private let stagingDirectoryURL: URL
    private let directoryLock: RuntimeQualificationHelperDirectoryLock

    static func prepare(
        priorURL: URL,
        installedURL: URL,
        priorSHA256: String,
        currentSHA256: String
    ) throws -> Self {
        guard priorURL.path != installedURL.path,
              priorURL.lastPathComponent == "hostwright-containerization-helper",
              installedURL.lastPathComponent == "hostwright-containerization-helper",
              isDigest(priorSHA256), isDigest(currentSHA256),
              priorSHA256 != currentSHA256,
              try fileSHA256(priorURL) == priorSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        let stagingDirectoryURL = installedURL.deletingLastPathComponent()
            .appendingPathComponent(
                stagingDirectoryName,
                isDirectory: true
            )
        let stagedURL = stagingDirectoryURL.appendingPathComponent(
            "hostwright-containerization-helper",
            isDirectory: false
        )
        let directoryLock = try RuntimeQualificationHelperDirectoryLock(
            directoryURL: installedURL.deletingLastPathComponent()
        )
        try recoverInterruptedTransitionIfPresent(
            installedURL: installedURL,
            stagedURL: stagedURL,
            stagingDirectoryURL: stagingDirectoryURL,
            priorSHA256: priorSHA256,
            currentSHA256: currentSHA256,
            directoryLock: directoryLock
        )
        guard try fileSHA256(installedURL) == currentSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        var createdStagingDirectory = false
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            createdStagingDirectory = true
            try FileManager.default.copyItem(at: priorURL, to: stagedURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: stagedURL.path
            )
            guard try fileSHA256(stagedURL) == priorSHA256 else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            try synchronizeFile(stagedURL)
            try synchronizeDirectory(stagingDirectoryURL)
            try synchronizeDirectory(installedURL.deletingLastPathComponent())
            return Self(
                installedURL: installedURL,
                stagedURL: stagedURL,
                priorSHA256: priorSHA256,
                currentSHA256: currentSHA256,
                stagingDirectoryURL: stagingDirectoryURL,
                directoryLock: directoryLock
            )
        } catch {
            if createdStagingDirectory {
                try? FileManager.default.removeItem(at: stagingDirectoryURL)
            }
            throw error
        }
    }

    func activatePrior() throws {
        guard try Self.fileSHA256(installedURL) == currentSHA256,
              try Self.fileSHA256(stagedURL) == priorSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        try swap()
        guard try Self.fileSHA256(installedURL) == priorSHA256,
              try Self.fileSHA256(stagedURL) == currentSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

    func restoreCurrent() throws {
        let installed = try Self.fileSHA256(installedURL)
        let staged = try Self.fileSHA256(stagedURL)
        if installed == priorSHA256, staged == currentSHA256 {
            try swap()
        } else if installed != currentSHA256 || staged != priorSHA256 {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        guard try Self.fileSHA256(installedURL) == currentSHA256,
              try Self.fileSHA256(stagedURL) == priorSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

    func removeStaging() throws {
        var directoryMetadata = stat()
        guard stagingDirectoryURL.deletingLastPathComponent()
                == installedURL.deletingLastPathComponent(),
              stagingDirectoryURL.lastPathComponent == Self.stagingDirectoryName,
              lstat(stagingDirectoryURL.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectoryURL.path
              ) == [stagedURL.lastPathComponent],
              try Self.fileSHA256(stagedURL) == priorSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        try FileManager.default.removeItem(at: stagedURL)
        try FileManager.default.removeItem(at: stagingDirectoryURL)
        try Self.synchronizeDirectory(installedURL.deletingLastPathComponent())
        guard !FileManager.default.fileExists(atPath: stagingDirectoryURL.path) else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

    private func swap() throws {
        guard renamex_np(
            installedURL.path,
            stagedURL.path,
            UInt32(RENAME_SWAP)
        ) == 0 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        try Self.synchronizeDirectory(installedURL.deletingLastPathComponent())
        try Self.synchronizeDirectory(stagingDirectoryURL)
    }

    private static func recoverInterruptedTransitionIfPresent(
        installedURL: URL,
        stagedURL: URL,
        stagingDirectoryURL: URL,
        priorSHA256: String,
        currentSHA256: String,
        directoryLock: RuntimeQualificationHelperDirectoryLock
    ) throws {
        var directoryMetadata = stat()
        errno = 0
        guard lstat(stagingDirectoryURL.path, &directoryMetadata) == 0 else {
            if errno == ENOENT { return }
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        guard stagingDirectoryURL.deletingLastPathComponent()
                == installedURL.deletingLastPathComponent(),
              stagingDirectoryURL.lastPathComponent == stagingDirectoryName,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == geteuid(),
              directoryMetadata.st_mode & 0o7777 == 0o700,
              try FileManager.default.contentsOfDirectory(
                atPath: stagingDirectoryURL.path
              ) == [stagedURL.lastPathComponent] else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        let interrupted = Self(
            installedURL: installedURL,
            stagedURL: stagedURL,
            priorSHA256: priorSHA256,
            currentSHA256: currentSHA256,
            stagingDirectoryURL: stagingDirectoryURL,
            directoryLock: directoryLock
        )
        try interrupted.restoreCurrent()
        try interrupted.removeStaging()
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let identity = try SecureExecutableResolver.verify(
            path: url.path,
            ownershipPolicy: .rootOrCurrentUser
        )
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try SecureExecutableResolver.verifyUnchanged(identity)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
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
    let priorHelperURL: URL?

    init(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        scenario: RuntimeQualificationRecoveryScenario,
        localImage: String,
        priorHelperURL: URL? = nil
    ) {
        self.providerID = providerID
        self.expectedVersion = expectedVersion
        self.scenario = scenario
        self.localImage = localImage
        self.priorHelperURL = priorHelperURL
    }

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
              (scenario == .staleHelper) == (priorHelperURL != nil),
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
    let priorHelperSHA256: String?
    let currentHelperSHA256: String?
    let signedHelperTransitionVerified: Bool
    let rollbackDisposition: String?
    let rollbackFindingReasons: [String]
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
    let helperExecutableURL: URL?
    let recorder: RuntimeQualificationCommandRecorder

    static func make(
        providerID: RuntimeProviderID,
        expectedVersion: String,
        recorder: RuntimeQualificationCommandRecorder,
        helperExecutableURL: URL? = nil
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
                helperExecutableURL: nil,
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
                    executableURL: helperExecutableURL ?? configuration.executableURL,
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
                helperExecutableURL: helperExecutableURL ?? configuration.executableURL,
                recorder: recorder
            )
        default:
            throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
        }
        do {
            let snapshot = try await boundary.adapter.capabilitySnapshot()
            let version = try await boundary.adapter.runtimeVersion()
            guard snapshot.descriptor.providerID == providerID,
                  version == expectedVersion,
                  RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).isEmpty else {
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
            return boundary
        } catch {
            guard await boundary.shutdown() else {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            throw error
        }
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
        priorHelperURL: URL? = nil,
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
                localImage: localImage,
                priorHelperURL: priorHelperURL
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
        let priorHelperSHA256BeforeLaunch: String?
        let currentHelperSHA256BeforeTransition: String?
        var helperTransition: RuntimeQualificationInstalledHelperTransition?
        let helperExecutableURL: URL?
        if let priorHelperURL = specification.priorHelperURL {
            do {
                priorHelperSHA256BeforeLaunch = try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: priorHelperURL
                )
                let currentHelperURL = try Self.currentInstalledHelperURL()
                currentHelperSHA256BeforeTransition = try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: currentHelperURL
                )
                var socketMetadata = stat()
                let socketURL = try ContainerizationHelperClientConfiguration.installed(
                    hostExecutableURL: Bundle.main.executableURL
                ).socketURL
                errno = 0
                guard lstat(socketURL.path, &socketMetadata) == -1,
                      errno == ENOENT else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                let transition = try RuntimeQualificationInstalledHelperTransition.prepare(
                    priorURL: priorHelperURL,
                    installedURL: currentHelperURL,
                    priorSHA256: priorHelperSHA256BeforeLaunch!,
                    currentSHA256: currentHelperSHA256BeforeTransition!
                )
                helperTransition = transition
                try transition.activatePrior()
                guard try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: transition.installedURL
                ) == priorHelperSHA256BeforeLaunch,
                try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: transition.stagedURL
                ) == currentHelperSHA256BeforeTransition else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                helperExecutableURL = transition.installedURL
            } catch {
                if let helperTransition {
                    do {
                        try Self.restoreAndCleanInstalledHelper(helperTransition)
                    } catch {
                        throw RuntimeQualificationRecoveryDriverError.cleanupFailed
                    }
                }
                throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
            }
        } else {
            priorHelperSHA256BeforeLaunch = nil
            currentHelperSHA256BeforeTransition = nil
            helperTransition = nil
            helperExecutableURL = nil
        }
        var boundary: RuntimeQualificationRecoveryProviderBoundary
        do {
            boundary = try await .make(
                providerID: specification.providerID,
                expectedVersion: specification.expectedVersion,
                recorder: recorder,
                helperExecutableURL: helperExecutableURL
            )
        } catch let error as RuntimeQualificationRecoveryDriverError {
            if let helperTransition {
                do {
                    try Self.restoreAndCleanInstalledHelper(helperTransition)
                } catch {
                    throw RuntimeQualificationRecoveryDriverError.cleanupFailed
                }
            }
            throw error
        } catch {
            if let helperTransition {
                do {
                    try Self.restoreAndCleanInstalledHelper(helperTransition)
                } catch {
                    throw RuntimeQualificationRecoveryDriverError.cleanupFailed
                }
            }
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
            let recordRevision: Int
            if specification.scenario == .staleHelper {
                recordRevision = RuntimeProviderMetadataEvidence.legacyRevision
            } else if specification.scenario == .downgradeRefusal {
                recordRevision = RuntimeProviderMetadataEvidence.currentRevision + 1
            } else {
                recordRevision = RuntimeProviderMetadataEvidence.currentRevision
            }
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
            var freshPersistedEvidence: RuntimeProviderMetadataEvidence?
            var priorHelperSHA256: String?
            var currentHelperSHA256: String?
            var signedHelperTransitionVerified = false
            var rollbackDisposition: String?
            var rollbackFindingReasons: [String] = []
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
                guard let priorHelperURL = specification.priorHelperURL,
                      let priorBefore = priorHelperSHA256BeforeLaunch,
                      let currentBeforeTransition = currentHelperSHA256BeforeTransition,
                      let transition = helperTransition,
                      boundary.helperExecutableURL == transition.installedURL else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                let priorAfter = try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: priorHelperURL
                )
                guard priorBefore == priorAfter,
                      try RuntimeQualificationHelperSignatureVerifier.sha256(
                        of: transition.installedURL
                      ) == priorAfter,
                      Self.helperFingerprint(in: baselineSnapshot) == priorAfter else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                priorHelperSHA256 = priorAfter
                await recorder.record(
                    arguments: [
                        "hostwright-containerization-helper", "negotiate", "h1"
                    ],
                    exitStatus: 0
                )
                guard await boundary.shutdown() else {
                    throw RuntimeQualificationRecoveryDriverError.cleanupFailed
                }
                await recorder.record(
                    arguments: [
                        "hostwright-containerization-helper", "shutdown", "h1"
                    ],
                    exitStatus: 0
                )

                try Self.restoreAndCleanInstalledHelper(transition)
                helperTransition = nil
                let currentHelperURL = transition.installedURL
                let currentBefore = try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: currentHelperURL
                )
                guard currentBefore == currentBeforeTransition else {
                    throw RuntimeQualificationRecoveryDriverError.cleanupFailed
                }
                let currentBoundary = try await RuntimeQualificationRecoveryProviderBoundary.make(
                    providerID: specification.providerID,
                    expectedVersion: specification.expectedVersion,
                    recorder: recorder,
                    helperExecutableURL: currentHelperURL
                )
                boundary = currentBoundary
                let currentAfter = try RuntimeQualificationHelperSignatureVerifier.sha256(
                    of: currentHelperURL
                )
                guard currentBefore == currentAfter,
                      priorAfter != currentAfter else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                currentHelperSHA256 = currentAfter
                await recorder.record(
                    arguments: [
                        "hostwright-containerization-helper", "negotiate", "h2"
                    ],
                    exitStatus: 0
                )
                let currentImage = try await boundary.adapter.localImageEvidence(
                    for: specification.localImage
                )
                guard currentImage == image else {
                    throw RuntimeQualificationRecoveryDriverError.runtimeInventoryChanged
                }
                evaluationSnapshot = try await boundary.adapter.capabilitySnapshot()
                guard Self.helperFingerprint(in: evaluationSnapshot) == currentAfter else {
                    throw RuntimeQualificationRecoveryDriverError.providerPreflightFailed
                }
                let beforePersistence = RuntimeProviderRecoveryEvaluator.evaluate(
                    record: record,
                    currentSnapshot: evaluationSnapshot,
                    metadataSupport: RuntimeProviderMetadataSupport(
                        minimumReadableRevision: RuntimeProviderMetadataEvidence.legacyRevision,
                        currentWritableRevision: RuntimeProviderMetadataEvidence.currentRevision
                    )
                )
                try Self.verifyStaleHelperBeforePersistence(beforePersistence)
                freshPersistedEvidence = try RuntimeProviderMetadataEvidence.parse(
                    entries: RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
                        to: [],
                        capabilitySHA256: evaluationSnapshot.canonicalSHA256
                    )
                )
                contractInput = "signed-h1-to-h2-helper-transition"
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
                ),
                freshPersistedEvidence: freshPersistedEvidence
            )
            try Self.verify(evaluation, for: specification.scenario)
            if specification.scenario == .staleHelper {
                let rollbackRecord = RuntimeProviderRecoveryRecord(
                    persistedProviderBinding: specification.providerID.rawValue,
                    providerGeneration: evaluation.providerGeneration,
                    providerMetadataRevision: evaluation.nextProviderMetadataRevision,
                    fingerprint: RuntimeProviderRecoveryFingerprint(
                        snapshot: evaluationSnapshot
                    )
                )
                let rollback = RuntimeProviderRecoveryEvaluator.evaluate(
                    record: rollbackRecord,
                    currentSnapshot: baselineSnapshot,
                    metadataSupport: RuntimeProviderMetadataSupport(
                        minimumReadableRevision: RuntimeProviderMetadataEvidence.legacyRevision,
                        currentWritableRevision: RuntimeProviderMetadataEvidence.legacyRevision
                    )
                )
                try Self.verifyStaleHelperRollback(rollback)
                rollbackDisposition = rollback.disposition.rawValue
                rollbackFindingReasons = rollback.findings.map(\.reason.rawValue)
                signedHelperTransitionVerified = true
            }
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
            if specification.scenario == .staleHelper {
                await recorder.record(
                    arguments: [
                        "hostwright-containerization-helper", "shutdown", "h2"
                    ],
                    exitStatus: 0
                )
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
                priorHelperSHA256: priorHelperSHA256,
                currentHelperSHA256: currentHelperSHA256,
                signedHelperTransitionVerified: signedHelperTransitionVerified,
                rollbackDisposition: rollbackDisposition,
                rollbackFindingReasons: rollbackFindingReasons,
                contractInput: contractInput,
                durableCheckpointBefore: checkpointBefore,
                durableCheckpointAfter: checkpointAfter,
                terminatedExecutable: terminatedExecutable,
                processTreeTerminated: processTreeTerminated,
                stateSchemaVersion: stateSchemaVersion,
                passedAssertions: specification.scenario == .staleHelper ? 14 : 8,
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
            if let helperTransition {
                do {
                    try Self.restoreAndCleanInstalledHelper(helperTransition)
                } catch {
                    cleaned = false
                }
            }
            guard cleaned, stopped else {
                throw RuntimeQualificationRecoveryDriverError.cleanupFailed
            }
            throw original
        }
    }

}

private extension RuntimeQualificationRecoveryDriver {
    static func restoreAndCleanInstalledHelper(
        _ transition: RuntimeQualificationInstalledHelperTransition
    ) throws {
        try transition.restoreCurrent()
        guard try RuntimeQualificationHelperSignatureVerifier.sha256(
            of: transition.installedURL
        ) == transition.currentSHA256,
        try RuntimeQualificationHelperSignatureVerifier.sha256(
            of: transition.stagedURL
        ) == transition.priorSHA256 else {
            throw RuntimeQualificationRecoveryDriverError.cleanupFailed
        }
        try transition.removeStaging()
    }

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
                evaluation.invalidatesCapabilitySnapshot &&
                evaluation.nextProviderMetadataRevision ==
                    RuntimeProviderMetadataEvidence.currentRevision
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

    static func verifyStaleHelperBeforePersistence(
        _ evaluation: RuntimeProviderRecoveryEvaluation
    ) throws {
        guard evaluation.findings.isEmpty,
              evaluation.disposition == .reobserveThenResumeFromCheckpoint,
              evaluation.invalidatesCapabilitySnapshot,
              evaluation.providerGeneration == 1,
              evaluation.nextProviderMetadataRevision ==
                RuntimeProviderMetadataEvidence.legacyRevision else {
            throw RuntimeQualificationRecoveryDriverError.expectedRecoveryDecisionMissing
        }
    }

    static func verifyStaleHelperRollback(
        _ evaluation: RuntimeProviderRecoveryEvaluation
    ) throws {
        let reasons = Set(evaluation.findings.map(\.reason))
        guard evaluation.disposition == .refuseAndPreserveCheckpoint,
              reasons == [.metadataRevisionTooNew],
              evaluation.invalidatesCapabilitySnapshot,
              evaluation.providerGeneration == 1,
              evaluation.nextProviderMetadataRevision ==
                RuntimeProviderMetadataEvidence.currentRevision else {
            throw RuntimeQualificationRecoveryDriverError.expectedRecoveryDecisionMissing
        }
    }

    static func currentInstalledHelperURL() throws -> URL {
        guard let hostExecutableURL = Bundle.main.executableURL else {
            throw RuntimeQualificationRecoveryDriverError.hostwrightExecutableUnavailable
        }
        return try ContainerizationHelperClientConfiguration.installed(
            hostExecutableURL: hostExecutableURL
        ).executableURL
    }

    static func helperFingerprint(in snapshot: RuntimeCapabilitySnapshot) -> String? {
        let helpers = snapshot.descriptor.components.filter {
            $0.identifier == .appleContainerizationHelper
        }
        guard helpers.count == 1 else { return nil }
        return helpers[0].fingerprint
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
