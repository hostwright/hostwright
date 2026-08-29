import Darwin
import Foundation
import HostwrightCore

public struct ManagedEtcdInstallReport: Codable, Equatable, Sendable {
    public let installDirectory: String
    public let executablePath: String
    public let provenancePath: String
    public let installedPaths: [String]
    public let recoveredStagingPaths: [String]

    public init(
        installDirectory: String,
        executablePath: String,
        provenancePath: String,
        installedPaths: [String],
        recoveredStagingPaths: [String]
    ) {
        self.installDirectory = installDirectory
        self.executablePath = executablePath
        self.provenancePath = provenancePath
        self.installedPaths = installedPaths
        self.recoveredStagingPaths = recoveredStagingPaths
    }
}

public struct ManagedEtcdInstaller: Sendable {
    public init() {}

    public func recoverStaging(
        layout: ManagedEtcdLayout,
        fileManager: FileManager = .default
    ) throws -> [String] {
        try layout.validate()
        guard ManagedEtcdRuntimeFileSystem.exists(layout.runtimeDirectory) else {
            return []
        }
        try ManagedEtcdRuntimeFileSystem.requirePrivateDirectory(layout.runtimeDirectory)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: layout.runtimeDirectory).sorted()
        } catch {
            throw ManagedEtcdError.installationFailed("managed runtime directory could not be inspected")
        }
        var recovered: [String] = []
        for name in names where name.hasPrefix("install-stage-") {
            let suffix = String(name.dropFirst("install-stage-".count))
            guard ManagedEtcdRuntimePath.isSafeOpaqueID(suffix) else {
                continue
            }
            let path = layout.runtimeDirectory + "/" + name
            try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(path, fileManager: fileManager)
            recovered.append(path)
        }
        return recovered
    }

    public func install(
        verifiedArchive: ManagedEtcdVerifiedArchive,
        layout: ManagedEtcdLayout,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation(),
        fileManager: FileManager = .default
    ) throws -> ManagedEtcdInstallReport {
        try layout.validate()
        guard verifiedArchive.artifact == layout.artifact else {
            throw ManagedEtcdError.installationRefused("verified archive does not match the layout artifact")
        }
        guard !cancellation.isCancelled else {
            throw ManagedEtcdError.cancelled
        }

        let recovered = try recoverStaging(layout: layout, fileManager: fileManager)
        _ = try layout.prepareDirectories(fileManager: fileManager)
        let stageName = "install-stage-" + UUID().uuidString.lowercased()
        guard ManagedEtcdRuntimePath.isSafeOpaqueID(String(stageName.dropFirst("install-stage-".count))) else {
            throw ManagedEtcdError.installationFailed("staging identifier is unsafe")
        }
        let stageDirectory = layout.runtimeDirectory + "/" + stageName
        try ManagedEtcdRuntimeFileSystem.createPrivateDirectory(stageDirectory, fileManager: fileManager)
        var publishedInstall = false
        var publishedProvenance = false

        do {
            let stagedArchive = stageDirectory + "/" + layout.artifact.archiveFileName
            try ManagedEtcdRuntimeFileSystem.copyRegularFile(
                from: verifiedArchive.archivePath,
                to: stagedArchive,
                cancellation: cancellation,
                fileManager: fileManager
            )
            let verifier = ManagedEtcdArtifactVerifier()
            let reverifiedArchive = try verifier.accept(
                artifact: layout.artifact,
                archiveURL: URL(fileURLWithPath: stagedArchive),
                cancellation: cancellation
            )
            guard reverifiedArchive.archiveSHA256 == layout.artifact.sha256 else {
                throw ManagedEtcdError.installationRefused("archive digest changed during installation")
            }

            let extractionDirectory = stageDirectory + "/extracted"
            try ManagedEtcdRuntimeFileSystem.createPrivateDirectory(extractionDirectory, fileManager: fileManager)
            try extract(
                archive: stagedArchive,
                artifact: layout.artifact,
                destination: extractionDirectory,
                cancellation: cancellation
            )
            let extractedRoot = extractionDirectory + "/" + layout.artifact.archiveRoot
            _ = try ManagedEtcdRuntimeFileSystem.validateExtractedTree(
                root: extractedRoot,
                artifact: layout.artifact,
                cancellation: cancellation
            )

            guard !ManagedEtcdRuntimeFileSystem.exists(layout.provenancePath) else {
                throw ManagedEtcdError.installationRefused("provenance already exists")
            }
            try ManagedEtcdRuntimeFileSystem.removeEmptyDirectory(
                layout.installDirectory,
                fileManager: fileManager
            )
            try fileManager.moveItem(atPath: extractedRoot, toPath: layout.installDirectory)
            publishedInstall = true
            try ManagedEtcdRuntimeFileSystem.writeCanonicalJSON(
                reverifiedArchive.provenance.canonicalJSON(),
                to: layout.provenancePath,
                fileManager: fileManager
            )
            publishedProvenance = true

            let installedPaths = try ManagedEtcdRuntimeFileSystem.collectPrivateTree(
                root: layout.installDirectory,
                cancellation: cancellation,
                executablePath: layout.executablePath
            )
            try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(stageDirectory, fileManager: fileManager)
            return ManagedEtcdInstallReport(
                installDirectory: layout.installDirectory,
                executablePath: layout.executablePath,
                provenancePath: layout.provenancePath,
                installedPaths: installedPaths + [layout.provenancePath],
                recoveredStagingPaths: recovered
            )
        } catch {
            var cleanupFailure: ManagedEtcdError?
            if publishedProvenance {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedRegularFile(
                        layout.provenancePath,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailure = .cleanupRefused(layout.provenancePath)
                }
            }
            if publishedInstall {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(
                        layout.installDirectory,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailure = .cleanupRefused(layout.installDirectory)
                }
            }
            do {
                try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(stageDirectory, fileManager: fileManager)
            } catch {
                cleanupFailure = .cleanupRefused(stageDirectory)
            }
            if let cleanupFailure {
                throw cleanupFailure
            }
            throw error
        }
    }

    private func extract(
        archive: String,
        artifact: ManagedEtcdArtifact,
        destination: String,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard !cancellation.isCancelled else {
            throw ManagedEtcdError.cancelled
        }
        let executable: String
        let arguments: [String]
        switch artifact.archiveKind {
        case .zip:
            executable = "/usr/bin/unzip"
            arguments = ["-q", "-o", archive, "-d", destination]
        case .tarGz:
            executable = "/usr/bin/tar"
            arguments = ["-xzf", archive, "-C", destination, "--no-same-owner", "--no-same-permissions"]
        }
        let request = SecureSubprocessRequest(
            executablePath: executable,
            arguments: arguments,
            environment: SecureSubprocessEnvironment.minimal,
            workingDirectory: "/",
            timeoutMilliseconds: 120_000,
            terminationGraceMilliseconds: 1_000,
            maximumStandardOutputBytes: 1 * 1_024 * 1_024,
            maximumStandardErrorBytes: 1 * 1_024 * 1_024
        )
        do {
            let result = try SecureSubprocessRunner().run(request, cancellation: cancellation)
            guard result.exitStatus == 0 else {
                throw ManagedEtcdError.installationFailed("archive extraction failed")
            }
        } catch let error as SecureSubprocessError {
            if case .cancelled = error {
                throw ManagedEtcdError.cancelled
            }
            throw ManagedEtcdError.installationFailed("archive extractor was unavailable or failed")
        }
    }
}

public struct ManagedEtcdSnapshotExecutionReport: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let destinationDirectory: String
    public let provenancePath: String
    public let copiedPaths: [String]

    public init(
        snapshotID: String,
        destinationDirectory: String,
        provenancePath: String,
        copiedPaths: [String]
    ) {
        self.snapshotID = snapshotID
        self.destinationDirectory = destinationDirectory
        self.provenancePath = provenancePath
        self.copiedPaths = copiedPaths
    }
}

public struct ManagedEtcdRestoreExecutionReport: Codable, Equatable, Sendable {
    public let snapshotDirectory: String
    public let targetDataDirectory: String
    public let backupDirectory: String
    public let restoredPaths: [String]

    public init(
        snapshotDirectory: String,
        targetDataDirectory: String,
        backupDirectory: String,
        restoredPaths: [String]
    ) {
        self.snapshotDirectory = snapshotDirectory
        self.targetDataDirectory = targetDataDirectory
        self.backupDirectory = backupDirectory
        self.restoredPaths = restoredPaths
    }
}

private struct ManagedEtcdSnapshotMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let snapshotID: String
    let sourceDataDirectory: String
    let artifactSHA256: String

    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeCanonical(_ data: Data) throws -> Self {
        let value: Self
        do {
            value = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ManagedEtcdError.restoreRefused("snapshot provenance is malformed")
        }
        guard value.schemaVersion == 1 else {
            throw ManagedEtcdError.restoreRefused("snapshot provenance schema is unsupported")
        }
        guard try value.canonicalJSON() == data else {
            throw ManagedEtcdError.restoreRefused("snapshot provenance is not canonical")
        }
        return value
    }
}

public struct ManagedEtcdSnapshotExecutor: Sendable {
    public init() {}

    public func createSnapshot(
        plan: ManagedEtcdSnapshotPlan,
        layout: ManagedEtcdLayout,
        processState: ManagedEtcdMemberState,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation(),
        fileManager: FileManager = .default
    ) throws -> ManagedEtcdSnapshotExecutionReport {
        try validateSnapshotPlan(plan, layout: layout)
        try requireStopped(processState)
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        try ManagedEtcdRuntimeFileSystem.requirePrivateDirectory(plan.sourceDataDirectory)
        guard !ManagedEtcdRuntimeFileSystem.exists(plan.destinationDirectory) else {
            throw ManagedEtcdError.snapshotFailed("snapshot destination already exists")
        }
        let stage = layout.runtimeDirectory + "/snapshot-stage-" + plan.snapshotID
        guard ManagedEtcdRuntimePath.isSafeOpaqueID("snapshot-stage-" + plan.snapshotID) else {
            throw ManagedEtcdError.snapshotFailed("snapshot staging identifier is unsafe")
        }
        try ManagedEtcdRuntimeFileSystem.createPrivateDirectory(stage, fileManager: fileManager)
        var publishedDestination = false
        var publishedProvenance = false
        do {
            try ManagedEtcdRuntimeFileSystem.copyTree(
                from: plan.sourceDataDirectory,
                to: stage,
                cancellation: cancellation,
                fileManager: fileManager
            )
            try fileManager.moveItem(atPath: stage, toPath: plan.destinationDirectory)
            publishedDestination = true
            let provenancePath = layout.metadataDirectory + "/snapshot-" + plan.snapshotID + ".json"
            guard !ManagedEtcdRuntimeFileSystem.exists(provenancePath) else {
                try? ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(
                    plan.destinationDirectory,
                    fileManager: fileManager
                )
                throw ManagedEtcdError.snapshotFailed("snapshot provenance already exists")
            }
            let metadata = ManagedEtcdSnapshotMetadata(
                schemaVersion: 1,
                snapshotID: plan.snapshotID,
                sourceDataDirectory: plan.sourceDataDirectory,
                artifactSHA256: layout.artifact.sha256
            )
            try ManagedEtcdRuntimeFileSystem.writeCanonicalJSON(
                try metadata.canonicalJSON(),
                to: provenancePath,
                fileManager: fileManager
            )
            publishedProvenance = true
            let copiedPaths = try ManagedEtcdRuntimeFileSystem.collectPrivateTree(
                root: plan.destinationDirectory,
                cancellation: cancellation
            )
            return ManagedEtcdSnapshotExecutionReport(
                snapshotID: plan.snapshotID,
                destinationDirectory: plan.destinationDirectory,
                provenancePath: provenancePath,
                copiedPaths: copiedPaths
            )
        } catch {
            var cleanupFailure: ManagedEtcdError?
            let provenancePath = layout.metadataDirectory + "/snapshot-" + plan.snapshotID + ".json"
            if publishedProvenance {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedRegularFile(
                        provenancePath,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailure = .cleanupRefused(provenancePath)
                }
            }
            if publishedDestination {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(
                        plan.destinationDirectory,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailure = .cleanupRefused(plan.destinationDirectory)
                }
            }
            if ManagedEtcdRuntimeFileSystem.exists(stage) {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(stage, fileManager: fileManager)
                } catch {
                    cleanupFailure = .cleanupRefused(stage)
                }
            }
            if let cleanupFailure {
                throw cleanupFailure
            }
            throw error
        }
    }

    public func restore(
        plan: ManagedEtcdRestorePlan,
        layout: ManagedEtcdLayout,
        processState: ManagedEtcdMemberState,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation(),
        fileManager: FileManager = .default
    ) throws -> ManagedEtcdRestoreExecutionReport {
        try layout.validate()
        try requireStopped(processState)
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        guard plan.targetDataDirectory == layout.dataDirectory,
              plan.backupDirectory == layout.runtimeDirectory + "/restore-backup",
              plan.snapshotDirectory != layout.snapshotsDirectory,
              ManagedEtcdRuntimePath.isWithin(plan.snapshotDirectory, root: layout.snapshotsDirectory) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(plan.snapshotDirectory)
        }
        try ManagedEtcdRuntimeFileSystem.requirePrivateDirectory(plan.snapshotDirectory)
        let snapshotID = String(
            plan.snapshotDirectory.dropFirst((layout.snapshotsDirectory + "/").count)
        )
        guard ManagedEtcdRuntimePath.isSafeOpaqueID(snapshotID) else {
            throw ManagedEtcdError.restoreRefused("snapshot identifier is unsafe")
        }
        let provenancePath = layout.metadataDirectory + "/snapshot-" + snapshotID + ".json"
        let metadata = try ManagedEtcdRuntimeFileSystem.readSnapshotMetadata(
            at: provenancePath
        )
        guard metadata.snapshotID == snapshotID,
              metadata.sourceDataDirectory == layout.dataDirectory,
              metadata.artifactSHA256 == layout.artifact.sha256 else {
            throw ManagedEtcdError.restoreRefused("snapshot provenance does not match the layout")
        }
        guard !ManagedEtcdRuntimeFileSystem.exists(plan.backupDirectory) else {
            throw ManagedEtcdError.restoreRefused("restore backup already exists")
        }
        guard ManagedEtcdRuntimePath.isSafeOpaqueID("restore-stage") else {
            throw ManagedEtcdError.restoreRefused("restore staging identifier is unsafe")
        }

        let stage = layout.runtimeDirectory + "/restore-stage"
        try ManagedEtcdRuntimeFileSystem.createPrivateDirectory(stage, fileManager: fileManager)
        var targetMovedToBackup = false
        var restoredTargetPublished = false
        do {
            if ManagedEtcdRuntimeFileSystem.exists(plan.targetDataDirectory) {
                try ManagedEtcdRuntimeFileSystem.requirePrivateDirectory(plan.targetDataDirectory)
                try fileManager.moveItem(atPath: plan.targetDataDirectory, toPath: plan.backupDirectory)
                targetMovedToBackup = true
            }
            try ManagedEtcdRuntimeFileSystem.copyTree(
                from: plan.snapshotDirectory,
                to: stage,
                cancellation: cancellation,
                fileManager: fileManager
            )
            try fileManager.moveItem(atPath: stage, toPath: plan.targetDataDirectory)
            restoredTargetPublished = true
            let restoredPaths = try ManagedEtcdRuntimeFileSystem.collectPrivateTree(
                root: plan.targetDataDirectory,
                cancellation: cancellation
            )
            return ManagedEtcdRestoreExecutionReport(
                snapshotDirectory: plan.snapshotDirectory,
                targetDataDirectory: plan.targetDataDirectory,
                backupDirectory: plan.backupDirectory,
                restoredPaths: restoredPaths
            )
        } catch {
            var cleanupFailure: ManagedEtcdError?
            if ManagedEtcdRuntimeFileSystem.exists(stage) {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(stage, fileManager: fileManager)
                } catch {
                    cleanupFailure = .cleanupRefused(stage)
                }
            }
            if restoredTargetPublished,
               ManagedEtcdRuntimeFileSystem.exists(plan.targetDataDirectory) {
                do {
                    try ManagedEtcdRuntimeFileSystem.removeOwnedDirectory(
                        plan.targetDataDirectory,
                        fileManager: fileManager
                    )
                } catch {
                    cleanupFailure = .cleanupRefused(plan.targetDataDirectory)
                }
            }
            if targetMovedToBackup,
               !ManagedEtcdRuntimeFileSystem.exists(plan.targetDataDirectory),
               ManagedEtcdRuntimeFileSystem.exists(plan.backupDirectory) {
                do {
                    try fileManager.moveItem(atPath: plan.backupDirectory, toPath: plan.targetDataDirectory)
                } catch {
                    cleanupFailure = .cleanupRefused(plan.backupDirectory)
                }
            }
            if let cleanupFailure {
                throw cleanupFailure
            }
            throw error
        }
    }

    private func validateSnapshotPlan(
        _ plan: ManagedEtcdSnapshotPlan,
        layout: ManagedEtcdLayout
    ) throws {
        try layout.validate()
        guard plan.sourceDataDirectory == layout.dataDirectory,
              plan.destinationDirectory == layout.snapshotsDirectory + "/" + plan.snapshotID,
              ManagedEtcdRuntimePath.isSafeOpaqueID(plan.snapshotID) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(plan.destinationDirectory)
        }
    }

    private func requireStopped(_ state: ManagedEtcdMemberState) throws {
        guard state == .stopped else {
            throw ManagedEtcdError.restoreRefused("managed etcd process must be stopped")
        }
    }
}

public enum ManagedEtcdMemberState: String, Codable, Equatable, Sendable {
    case stopped
    case starting
    case running
    case healthy
    case unhealthy
    case stopping
    case failed
    case cancelled
}

public struct ManagedEtcdMemberStatus: Codable, Equatable, Sendable {
    public let state: ManagedEtcdMemberState
    public let processID: Int32?
    public let lastHealthCheckSucceeded: Bool?

    public init(
        state: ManagedEtcdMemberState,
        processID: Int32?,
        lastHealthCheckSucceeded: Bool?
    ) {
        self.state = state
        self.processID = processID
        self.lastHealthCheckSucceeded = lastHealthCheckSucceeded
    }
}

public actor ManagedEtcdMemberSupervisor {
    private let configuration: ManagedEtcdSupervisedProcessConfiguration
    private let healthEndpoint: URL
    private var process: SecureDetachedProcess?
    private var processID: Int32?
    private var state: ManagedEtcdMemberState = .stopped
    private var lastHealthCheckSucceeded: Bool?

    public init(
        configuration: ManagedEtcdSupervisedProcessConfiguration,
        healthEndpoint: URL
    ) throws {
        try configuration.validate()
        guard healthEndpoint.scheme == "https",
              healthEndpoint.host != nil,
              healthEndpoint.user == nil,
              healthEndpoint.password == nil,
              healthEndpoint.query == nil,
              healthEndpoint.fragment == nil else {
            throw ManagedEtcdError.invalidLayout("health endpoint is not a credential-free HTTPS URL")
        }
        self.configuration = configuration
        self.healthEndpoint = healthEndpoint
    }

    public func status() -> ManagedEtcdMemberStatus {
        ManagedEtcdMemberStatus(
            state: state,
            processID: processID,
            lastHealthCheckSucceeded: lastHealthCheckSucceeded
        )
    }

    public func start() async throws -> ManagedEtcdMemberStatus {
        guard state == .stopped || state == .failed || state == .cancelled else {
            throw ManagedEtcdError.processAlreadyRunning
        }
        guard !Task.isCancelled else {
            state = .cancelled
            throw ManagedEtcdError.cancelled
        }
        try configuration.validate()
        state = .starting
        lastHealthCheckSucceeded = nil
        do {
            process = try SecureSubprocessRunner().launchDetached(
                configuration.secureSubprocessRequest()
            )
        } catch {
            state = .failed
            throw ManagedEtcdError.processStartFailed("secure subprocess launch failed")
        }
        guard let process, process.isRunning else {
            state = .failed
            self.process = nil
            throw ManagedEtcdError.processStartFailed("process exited before supervision began")
        }
        processID = process.processID
        state = .running
        return status()
    }

    public func checkHealth() async throws -> ManagedEtcdMemberStatus {
        guard let process, process.isRunning,
              state == .running || state == .healthy || state == .unhealthy else {
            self.process = nil
            state = .failed
            processID = nil
            throw ManagedEtcdError.processNotRunning
        }
        var request = URLRequest(url: healthEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw ManagedEtcdError.healthCheckFailed("health endpoint returned a non-success status")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let health = object["health"] as? String,
                  health == "true" else {
                throw ManagedEtcdError.healthCheckFailed("health endpoint returned an invalid payload")
            }
            lastHealthCheckSucceeded = true
            state = .healthy
            return status()
        } catch let error as ManagedEtcdError {
            lastHealthCheckSucceeded = false
            state = .unhealthy
            throw error
        } catch {
            lastHealthCheckSucceeded = false
            state = .unhealthy
            throw ManagedEtcdError.healthCheckFailed("health endpoint was unavailable")
        }
    }

    public func stop() async -> ManagedEtcdMemberStatus {
        guard let process else {
            processID = nil
            state = .stopped
            lastHealthCheckSucceeded = nil
            return status()
        }
        state = .stopping
        process.terminate(graceMilliseconds: configuration.terminationGraceMilliseconds)
        self.process = nil
        processID = nil
        state = .stopped
        lastHealthCheckSucceeded = nil
        return status()
    }
}

private enum ManagedEtcdRuntimePath {
    static func isSafeOpaqueID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 45 || scalar.value == 46 || scalar.value == 95 ||
                (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 65 && scalar.value <= 90) ||
                (scalar.value >= 97 && scalar.value <= 122)
        }
    }

    static func isSafeAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.contains("\0"),
              !path.contains("//"), !path.hasSuffix("/"), path.utf8.count <= Int(PATH_MAX) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: true)
            .allSatisfy { $0 != "." && $0 != ".." }
    }

    static func isWithin(_ path: String, root: String) -> Bool {
        guard isSafeAbsolutePath(path), isSafeAbsolutePath(root) else { return false }
        return path == root || path.hasPrefix(root + "/")
    }
}

private enum ManagedEtcdRuntimeFileSystem {
    static func exists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    static func createPrivateDirectory(_ path: String, fileManager: FileManager) throws {
        guard ManagedEtcdRuntimePath.isSafeAbsolutePath(path) else {
            throw ManagedEtcdError.invalidLayout(path)
        }
        guard !exists(path) else {
            try requirePrivateDirectory(path)
            guard chmod(path, 0o700) == 0 else {
                throw ManagedEtcdError.unsafePermissions(path)
            }
            return
        }
        do {
            try fileManager.createDirectory(
                atPath: path,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ManagedEtcdError.installationFailed("private directory could not be created")
        }
        guard chmod(path, 0o700) == 0 else {
            throw ManagedEtcdError.unsafePermissions(path)
        }
    }

    static func requirePrivateDirectory(_ path: String) throws {
        guard ManagedEtcdRuntimePath.isSafeAbsolutePath(path) else {
            throw ManagedEtcdError.pathOutsideOwnedBoundary(path)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw ManagedEtcdError.snapshotFailed("private directory is missing")
        }
        guard metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw ManagedEtcdError.unsafePermissions(path)
        }
    }

    static func removeEmptyDirectory(_ path: String, fileManager: FileManager) throws {
        guard exists(path) else { return }
        try requirePrivateDirectory(path)
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            throw ManagedEtcdError.installationRefused("directory contents could not be inspected")
        }
        guard contents.isEmpty else {
            throw ManagedEtcdError.installationRefused("installation destination is not empty")
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw ManagedEtcdError.installationRefused("empty installation destination could not be removed")
        }
    }

    static func removeOwnedDirectory(_ path: String, fileManager: FileManager) throws {
        guard ManagedEtcdRuntimePath.isSafeAbsolutePath(path) else {
            throw ManagedEtcdError.cleanupRefused(path)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw ManagedEtcdError.cleanupRefused(path)
        }
        guard metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_mode & 0o077 == 0 else {
            throw ManagedEtcdError.cleanupRefused(path)
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw ManagedEtcdError.cleanupRefused(path)
        }
    }

    static func removeOwnedRegularFile(_ path: String, fileManager: FileManager) throws {
        guard ManagedEtcdRuntimePath.isSafeAbsolutePath(path) else {
            throw ManagedEtcdError.cleanupRefused(path)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return }
            throw ManagedEtcdError.cleanupRefused(path)
        }
        guard metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_mode & 0o077 == 0 else {
            throw ManagedEtcdError.cleanupRefused(path)
        }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw ManagedEtcdError.cleanupRefused(path)
        }
    }

    static func copyRegularFile(
        from source: String,
        to destination: String,
        cancellation: SecureSubprocessCancellation,
        fileManager: FileManager
    ) throws {
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        var sourceMetadata = stat()
        guard lstat(source, &sourceMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == S_IFREG,
              sourceMetadata.st_uid == getuid(),
              sourceMetadata.st_nlink == 1,
              sourceMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ManagedEtcdError.archiveNotFound
        }
        let sourceHandle: FileHandle
        do {
            sourceHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: source))
        } catch {
            throw ManagedEtcdError.archiveUnreadable("archive could not be copied")
        }
        defer { try? sourceHandle.close() }

        let descriptor = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ManagedEtcdError.installationFailed("staged archive could not be created")
        }
        defer { close(descriptor) }
        do {
            while true {
                guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
                let data = try sourceHandle.read(upToCount: 1 * 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                try data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < data.count {
                        let written = Darwin.write(
                            descriptor,
                            buffer.baseAddress!.advanced(by: offset),
                            data.count - offset
                        )
                        if written < 0, errno == EINTR { continue }
                        guard written > 0 else { throw ManagedEtcdError.installationFailed("staged archive write failed") }
                        offset += written
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ManagedEtcdError.installationFailed("staged archive was not durable")
            }
        } catch {
            try? fileManager.removeItem(atPath: destination)
            throw error
        }
    }

    static func writeCanonicalJSON(
        _ data: Data,
        to destination: String,
        fileManager: FileManager
    ) throws {
        let temporary = destination + ".tmp-" + UUID().uuidString.lowercased()
        guard ManagedEtcdRuntimePath.isSafeOpaqueID(String(temporary.split(separator: "/").last ?? "")) else {
            throw ManagedEtcdError.installationFailed("metadata staging identifier is unsafe")
        }
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ManagedEtcdError.installationFailed("metadata file could not be created")
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen {
                close(descriptor)
            }
        }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < data.count {
                    let written = Darwin.write(
                        descriptor,
                        buffer.baseAddress!.advanced(by: offset),
                        data.count - offset
                    )
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw ManagedEtcdError.installationFailed("metadata write failed") }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else {
                throw ManagedEtcdError.installationFailed("metadata was not durable")
            }
            guard close(descriptor) == 0 else {
                throw ManagedEtcdError.installationFailed("metadata file could not be closed")
            }
            descriptorOpen = false
            try fileManager.moveItem(atPath: temporary, toPath: destination)
        } catch {
            try? fileManager.removeItem(atPath: temporary)
            throw error
        }
    }

    static func readSnapshotMetadata(at path: String) throws -> ManagedEtcdSnapshotMetadata {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o077 == 0 else {
            throw ManagedEtcdError.restoreRefused("snapshot provenance is missing or unsafe")
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
            return try ManagedEtcdSnapshotMetadata.decodeCanonical(data)
        } catch let error as ManagedEtcdError {
            throw error
        } catch {
            throw ManagedEtcdError.restoreRefused("snapshot provenance could not be read")
        }
    }

    static func copyTree(
        from source: String,
        to destination: String,
        cancellation: SecureSubprocessCancellation,
        fileManager: FileManager
    ) throws {
        try requirePrivateDirectory(source)
        try createPrivateDirectory(destination, fileManager: fileManager)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: source).sorted()
        } catch {
            throw ManagedEtcdError.snapshotFailed("directory contents could not be inspected")
        }
        for name in names {
            guard ManagedEtcdRuntimePath.isSafeOpaqueID(name), !cancellation.isCancelled else {
                if cancellation.isCancelled { throw ManagedEtcdError.cancelled }
                throw ManagedEtcdError.snapshotFailed("snapshot entry name is unsafe")
            }
            let sourcePath = source + "/" + name
            let destinationPath = destination + "/" + name
            var metadata = stat()
            guard lstat(sourcePath, &metadata) == 0 else {
                throw ManagedEtcdError.snapshotFailed("snapshot entry disappeared")
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                try copyTree(
                    from: sourcePath,
                    to: destinationPath,
                    cancellation: cancellation,
                    fileManager: fileManager
                )
            case S_IFREG:
                guard metadata.st_uid == getuid(),
                      metadata.st_mode & 0o077 == 0 else {
                    throw ManagedEtcdError.unsafePermissions(sourcePath)
                }
                try copyRegularFile(
                    from: sourcePath,
                    to: destinationPath,
                    cancellation: cancellation,
                    fileManager: fileManager
                )
                guard chmod(destinationPath, 0o600) == 0 else {
                    throw ManagedEtcdError.unsafePermissions(destinationPath)
                }
            default:
                throw ManagedEtcdError.snapshotFailed("snapshot contains a link or special file")
            }
        }
    }

    static func validateExtractedTree(
        root: String,
        artifact: ManagedEtcdArtifact,
        cancellation: SecureSubprocessCancellation
    ) throws -> [String] {
        var metadata = stat()
        guard lstat(root, &metadata) == 0,
              metadata.st_uid == getuid(),
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ManagedEtcdError.unsafePermissions(root)
        }
        var paths: [String] = []
        try collect(
            root: root,
            current: root,
            artifact: artifact,
            cancellation: cancellation,
            paths: &paths
        )
        guard exists(artifactExecutable(root: root, artifact: artifact)) else {
            throw ManagedEtcdError.archiveMissingExecutable(artifact.executableEntryPath)
        }
        return paths.sorted()
    }

    static func collectPrivateTree(
        root: String,
        cancellation: SecureSubprocessCancellation,
        executablePath: String? = nil
    ) throws -> [String] {
        try requirePrivateDirectory(root)
        var paths: [String] = []
        try collectGeneric(
            root: root,
            current: root,
            cancellation: cancellation,
            executablePath: executablePath,
            paths: &paths
        )
        return paths.sorted()
    }

    private static func collect(
        root: String,
        current: String,
        artifact: ManagedEtcdArtifact,
        cancellation: SecureSubprocessCancellation,
        paths: inout [String]
    ) throws {
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        var metadata = stat()
        guard lstat(current, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw ManagedEtcdError.unsafePermissions(current)
        }
        let type = metadata.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else {
            throw ManagedEtcdError.unsafeArchiveEntryType(current)
        }
        if type == S_IFDIR {
            guard chmod(current, 0o700) == 0 else { throw ManagedEtcdError.unsafePermissions(current) }
            let names = try FileManager.default.contentsOfDirectory(atPath: current).sorted()
            for name in names {
                guard ManagedEtcdRuntimePath.isSafeOpaqueID(name) else {
                    throw ManagedEtcdError.unsafeArchivePath(name)
                }
                try collect(
                    root: root,
                    current: current + "/" + name,
                    artifact: artifact,
                    cancellation: cancellation,
                    paths: &paths
                )
            }
        } else {
            let executable = current == artifactExecutable(root: root, artifact: artifact)
            guard chmod(current, executable ? 0o700 : 0o600) == 0 else {
                throw ManagedEtcdError.unsafePermissions(current)
            }
        }
        paths.append(current)
    }

    private static func collectGeneric(
        root: String,
        current: String,
        cancellation: SecureSubprocessCancellation,
        executablePath: String?,
        paths: inout [String]
    ) throws {
        guard !cancellation.isCancelled else { throw ManagedEtcdError.cancelled }
        var metadata = stat()
        guard lstat(current, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw ManagedEtcdError.unsafePermissions(current)
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            guard chmod(current, 0o700) == 0 else { throw ManagedEtcdError.unsafePermissions(current) }
            let names = try FileManager.default.contentsOfDirectory(atPath: current).sorted()
            for name in names {
                guard ManagedEtcdRuntimePath.isSafeOpaqueID(name) else {
                    throw ManagedEtcdError.snapshotFailed("tree entry name is unsafe")
                }
                try collectGeneric(
                    root: root,
                    current: current + "/" + name,
                    cancellation: cancellation,
                    executablePath: executablePath,
                    paths: &paths
                )
            }
        case S_IFREG:
            let mode: mode_t = current == executablePath ? 0o700 : 0o600
            guard chmod(current, mode) == 0 else { throw ManagedEtcdError.unsafePermissions(current) }
        default:
            throw ManagedEtcdError.snapshotFailed("tree contains a link or special file")
        }
        paths.append(current)
    }

    private static func artifactExecutable(root: String, artifact: ManagedEtcdArtifact) -> String {
        root + "/" + String(artifact.executableEntryPath.dropFirst(artifact.archiveRoot.count + 1))
    }
}
