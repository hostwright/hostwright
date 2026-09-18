import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightState
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightStorage

public struct DistributionPreparedStateBinding: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let installationID: String
    public let preparedGeneration: Int
    public let ownerUID: UInt32
    public let databasePath: String
    public let localPathResolution: HostwrightLocalPathResolution?
    public let maintenancePaths: StateMaintenancePaths

    public var configuration: StateStoreConfiguration {
        localPathResolution.map(StateStoreConfiguration.init(localPathResolution:))
            ?? StateStoreConfiguration(explicitDatabasePath: databasePath)
    }
}

public struct DistributionStatePreparationChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let installationID: String
    public let generation: Int
    public let prefix: String
    public let installedManifestSHA256: String

    public func validate() throws {
        guard schemaVersion == 1, let id = UUID(uuidString: installationID),
              id.uuidString.lowercased() == installationID, generation >= 1,
              try HostwrightLocalPathResolver.normalizedAbsolutePath(prefix, role: "installation prefix") == prefix,
              installedManifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw DistributionError.lifecycleFailed("state preparation challenge is invalid")
        }
    }
}

public struct DistributionOwnerStateReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let challenge: DistributionStatePreparationChallenge
    public let binding: DistributionPreparedStateBinding
    public let preparedRevision: StateUpgradeRevision
    public let receiptPath: String
}

public enum DistributionLifecycleReadiness: String, Codable, Equatable, Sendable {
    case notInstalled = "not-installed"
    case ready
    case recoveryRequired = "recovery-required"
}

public struct DistributionLifecycleInspection: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let readiness: DistributionLifecycleReadiness
    public let status: DistributionInstallationStatus?
    public let pendingOperation: DistributionLifecycleJournal?

    public init(
        readiness: DistributionLifecycleReadiness,
        status: DistributionInstallationStatus?,
        pendingOperation: DistributionLifecycleJournal?
    ) {
        self.schemaVersion = 1
        self.kind = "distributionLifecycleInspection"
        self.readiness = readiness
        self.status = status
        self.pendingOperation = pendingOperation
    }
}

public enum DistributionRecoveryAction: String, Codable, Equatable, Sendable {
    case noAction = "no-action"
    case completedPublishedGeneration = "completed-published-generation"
    case completedUninstall = "completed-uninstall"
    case restoredPriorGeneration = "restored-prior-generation"
    case removedInterruptedInitialInstall = "removed-interrupted-initial-install"
}

public struct DistributionRecoveryResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let action: DistributionRecoveryAction
    public let operationID: String?
    public let status: DistributionInstallationStatus?

    public init(
        action: DistributionRecoveryAction,
        operationID: String?,
        status: DistributionInstallationStatus?
    ) {
        self.schemaVersion = 1
        self.kind = "distributionRecoveryResult"
        self.action = action
        self.operationID = operationID
        self.status = status
    }
}

public struct DistributionUninstallResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let dataPolicy: DistributionUninstallDataPolicy
    public let removedPaths: [String]
    public let removedStatePaths: [String]
    public let preservedStateDatabasePath: String?

    public init(
        dataPolicy: DistributionUninstallDataPolicy,
        removedPaths: [String],
        removedStatePaths: [String] = [],
        preservedStateDatabasePath: String?
    ) {
        self.schemaVersion = 1
        self.kind = "distributionUninstallResult"
        self.dataPolicy = dataPolicy
        self.removedPaths = removedPaths
        self.removedStatePaths = removedStatePaths
        self.preservedStateDatabasePath = preservedStateDatabasePath
    }
}

public struct DistributionUninstallPlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let prefix: String
    public let installationID: String
    public let generation: Int
    public let dataPolicy: DistributionUninstallDataPolicy
    public let stateDatabasePath: String?
    public let stateDatabaseExists: Bool
    public let stateDatabaseSHA256: String?
    public let stateDatabaseBytes: UInt64?
    public let stateSchemaVersion: Int?
    public let confirmationToken: String
    public let createdAt: String

    init(
        prefix: String,
        installationID: String,
        generation: Int,
        dataPolicy: DistributionUninstallDataPolicy,
        stateDatabasePath: String?,
        stateDatabaseExists: Bool,
        stateRevision: StateUpgradeRevision?,
        confirmationToken: String,
        createdAt: String
    ) {
        self.schemaVersion = 1
        self.kind = "distributionUninstallPlan"
        self.prefix = prefix
        self.installationID = installationID
        self.generation = generation
        self.dataPolicy = dataPolicy
        self.stateDatabasePath = stateDatabasePath
        self.stateDatabaseExists = stateDatabaseExists
        self.stateDatabaseSHA256 = stateRevision?.databaseSHA256
        self.stateDatabaseBytes = stateRevision?.databaseBytes
        self.stateSchemaVersion = stateRevision?.stateSchemaVersion
        self.confirmationToken = confirmationToken
        self.createdAt = createdAt
    }

    public func validate() throws {
        guard schemaVersion == 1,
              kind == "distributionUninstallPlan",
              try HostwrightLocalPathResolver.normalizedAbsolutePath(
                prefix,
                role: "distribution uninstall plan prefix"
              ) == prefix,
              DistributionLifecycleJournal.isCanonicalUUID(installationID),
              generation > 0,
              confirmationToken.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: createdAt) != nil else {
            throw DistributionError.lifecycleFailed("uninstall plan is invalid")
        }
        if let stateDatabasePath {
            guard try HostwrightLocalPathResolver.normalizedAbsolutePath(
                stateDatabasePath,
                role: "distribution uninstall plan state database"
            ) == stateDatabasePath else {
                throw DistributionError.lifecycleFailed("uninstall plan state path is invalid")
            }
        }
        let revisionFieldsAreComplete = stateDatabaseSHA256 != nil
            && stateDatabaseBytes != nil
            && stateSchemaVersion != nil
        guard stateDatabaseSHA256 == nil || revisionFieldsAreComplete,
              stateDatabaseBytes == nil || revisionFieldsAreComplete,
              stateSchemaVersion == nil || revisionFieldsAreComplete,
              !stateDatabaseExists || stateDatabasePath != nil else {
            throw DistributionError.lifecycleFailed("uninstall plan state revision is invalid")
        }
        if let stateDatabaseSHA256, let stateDatabaseBytes, let stateSchemaVersion {
            guard stateDatabasePath != nil,
                  stateDatabaseSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  stateDatabaseBytes > 0,
                  (0...MigrationRunner.latestSchemaVersion).contains(stateSchemaVersion) else {
                throw DistributionError.lifecycleFailed("uninstall plan state revision is invalid")
            }
        }
        switch dataPolicy {
        case .preserve:
            guard !revisionFieldsAreComplete else {
                throw DistributionError.lifecycleFailed(
                    "preserve-data planning must not inspect state content"
                )
            }
        case .remove:
            guard stateDatabasePath != nil,
                  stateDatabaseExists == revisionFieldsAreComplete else {
                throw DistributionError.lifecycleFailed(
                    "managed-data removal requires an installation-bound state database and verified current state revision"
                )
            }
        }
    }
}

public enum DistributionLifecycleInterruption: Error, Equatable, Sendable {
    case after(DistributionLifecycleCheckpoint)
    case afterStatusWriteBeforeJournal
    case afterCanonicalStageSynced(String)
    case afterUninstallTransactionsRemoved
    case afterCompensationFilesRestored(Int)
    case afterCompensationTransactionRemoved
    case afterPublishedTransactionCleanup
}

private struct DistributionRollbackRecord: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let operationID: String
    let priorGeneration: Int
    let priorManifest: DistributionInstallManifest
    let installedManifest: DistributionInstallManifest
    let backupRelativePath: String
    let stateSnapshot: DistributionStateSnapshotRecord?
    let serviceBefore: DistributionManagedServiceState
    let priorPackageOrigin: DistributionPackageOrigin?
    let createdAt: String

    init(
        operationID: String,
        priorGeneration: Int,
        priorManifest: DistributionInstallManifest,
        installedManifest: DistributionInstallManifest,
        backupRelativePath: String,
        stateSnapshot: DistributionStateSnapshotRecord?,
        serviceBefore: DistributionManagedServiceState,
        priorPackageOrigin: DistributionPackageOrigin? = nil,
        createdAt: String
    ) {
        self.schemaVersion = 1
        self.kind = "distributionRollbackRecord"
        self.operationID = operationID
        self.priorGeneration = priorGeneration
        self.priorManifest = priorManifest
        self.installedManifest = installedManifest
        self.backupRelativePath = backupRelativePath
        self.stateSnapshot = stateSnapshot
        self.serviceBefore = serviceBefore
        self.priorPackageOrigin = priorPackageOrigin
        self.createdAt = createdAt
    }

    func validate() throws {
        let transaction = "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)/\(operationID)"
        guard schemaVersion == 1,
              kind == "distributionRollbackRecord",
              DistributionLifecycleJournal.isCanonicalUUID(operationID),
              priorGeneration > 0,
              backupRelativePath == transaction + "/backup",
              ISO8601DateFormatter().date(from: createdAt) != nil,
              try DistributionVersionTransition.classify(
                installedVersion: priorManifest.packageVersion,
                installedCommit: priorManifest.sourceCommit,
                candidateVersion: installedManifest.packageVersion,
                candidateCommit: installedManifest.sourceCommit
              ) == .upgrade else {
            throw DistributionError.lifecycleFailed("rollback record is invalid")
        }
        try priorManifest.validate()
        try installedManifest.validate()
        try stateSnapshot?.validate(transactionRelativePath: transaction)
        try priorPackageOrigin?.validate()
        if let priorPackageOrigin {
            guard try DistributionPackageVersion.make(from: priorManifest.packageVersion)
                == priorPackageOrigin.packageVersion else {
                throw DistributionError.lifecycleFailed(
                    "rollback package origin is not bound to the prior manifest"
                )
            }
        }
    }
}

private struct DistributionPayloadBackupFile: Codable, Equatable {
    let path: String
    let sha256: String
    let sizeBytes: Int
    let mode: Int
}

private struct DistributionOwnedFileInspection {
    let sha256: String?
    let sizeBytes: Int
    let mode: Int
    let device: UInt64
    let inode: UInt64
}

private struct DistributionPayloadBackupInventory: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let files: [DistributionPayloadBackupFile]

    init(files: [DistributionPayloadBackupFile]) {
        self.schemaVersion = 1
        self.kind = "distributionPayloadBackupInventory"
        self.files = files.sorted { $0.path < $1.path }
    }

    func validate(manifest: DistributionInstallManifest) throws {
        let manifestPaths = Set(manifest.files.map(\.path))
        guard schemaVersion == 1,
              kind == "distributionPayloadBackupInventory",
              files.map(\.path) == files.map(\.path).sorted(),
              Set(files.map(\.path)).count == files.count,
              Set(files.map(\.path)).isSubset(of: manifestPaths) else {
            throw DistributionError.lifecycleFailed("payload backup inventory is invalid")
        }
        for file in files {
            guard DistributionPathPolicy.isSafeRelativePath(file.path),
                  file.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  file.sizeBytes > 0,
                  (0...0o777).contains(file.mode) else {
                throw DistributionError.lifecycleFailed("payload backup file metadata is invalid")
            }
        }
    }
}

struct DistributionManagedLaunchdServiceConfiguration: Equatable, Sendable {
    let domain: String
    let label: String
    let propertyListURL: URL

    static func currentUserHomebrew() -> Self {
        Self(
            domain: "gui/\(geteuid())",
            label: "homebrew.mxcl.hostwright",
            propertyListURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.hostwright.plist")
        )
    }
}

private struct DistributionManagedLaunchdServiceRecord {
    let programPath: String
    let configPath: String
}

public struct DistributionInstalledLifecycle: Sendable {
    private let runner: DistributionProcessRunner
    private let packageReceiptController: DistributionPackageReceiptController
    private let managedService: DistributionManagedLaunchdServiceConfiguration
    private let interruptAfter: DistributionLifecycleCheckpoint?
    private let cancelAfter: DistributionLifecycleCheckpoint?
    private let interruptAfterStatusWrite: Bool
    private let interruptAfterCanonicalStageWriteFor: String?
    private let interruptAfterUninstallTransactionsRemoved: Bool
    private let interruptAfterCompensationRestoreCount: Int?
    private let interruptAfterCompensationTransactionRemoved: Bool
    private let interruptAfterPublishedTransactionCleanup: Bool

    public init(runner: DistributionProcessRunner = DistributionProcessRunner()) {
        self.runner = runner
        self.packageReceiptController = DistributionPackageReceiptController(runner: runner)
        self.managedService = .currentUserHomebrew()
        self.interruptAfter = nil
        self.cancelAfter = nil
        self.interruptAfterStatusWrite = false
        self.interruptAfterCanonicalStageWriteFor = nil
        self.interruptAfterUninstallTransactionsRemoved = false
        self.interruptAfterCompensationRestoreCount = nil
        self.interruptAfterCompensationTransactionRemoved = false
        self.interruptAfterPublishedTransactionCleanup = false
    }

    init(
        runner: DistributionProcessRunner = DistributionProcessRunner(),
        packageReceiptController: DistributionPackageReceiptController? = nil,
        managedService: DistributionManagedLaunchdServiceConfiguration = .currentUserHomebrew(),
        interruptAfter: DistributionLifecycleCheckpoint? = nil,
        cancelAfter: DistributionLifecycleCheckpoint? = nil,
        interruptAfterStatusWrite: Bool = false,
        interruptAfterCanonicalStageWriteFor: String? = nil,
        interruptAfterUninstallTransactionsRemoved: Bool = false,
        interruptAfterCompensationRestoreCount: Int? = nil,
        interruptAfterCompensationTransactionRemoved: Bool = false,
        interruptAfterPublishedTransactionCleanup: Bool = false
    ) {
        self.runner = runner
        self.packageReceiptController = packageReceiptController
            ?? DistributionPackageReceiptController(runner: runner)
        self.managedService = managedService
        self.interruptAfter = interruptAfter
        self.cancelAfter = cancelAfter
        self.interruptAfterStatusWrite = interruptAfterStatusWrite
        self.interruptAfterCanonicalStageWriteFor = interruptAfterCanonicalStageWriteFor
        self.interruptAfterUninstallTransactionsRemoved =
            interruptAfterUninstallTransactionsRemoved
        self.interruptAfterCompensationRestoreCount = interruptAfterCompensationRestoreCount
        self.interruptAfterCompensationTransactionRemoved =
            interruptAfterCompensationTransactionRemoved
        self.interruptAfterPublishedTransactionCleanup = interruptAfterPublishedTransactionCleanup
    }

    public func exportStatePreparationChallenge(
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionStatePreparationChallenge {
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lock.release() }
        try refusePendingJournal(prefix)
        let status = try requiredStatus(prefix)
        try verifyOwnedFiles(status.installedManifest, prefix: prefix, cancellation: cancellation)
        let challenge = DistributionStatePreparationChallenge(schemaVersion: 1,
            installationID: status.installationID, generation: status.generation, prefix: prefix.path,
            installedManifestSHA256: try DistributionHash.sha256(fileURL: installManifestURL(prefix)))
        try challenge.validate()
        try writeCanonicalReplacing(challenge, to: statePreparationChallengeURL(prefix), mode: 0o644)
        return challenge
    }

    public func prepareOwnerStateReceipt(
        prefix: URL,
        configuration: StateStoreConfiguration,
        requireEmptyIdentityAuthority: Bool = false,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionOwnerStateReceipt {
        guard geteuid() != 0 else {
            throw DistributionError.lifecycleFailed("owner state preparation must run as the state owner")
        }
        let challenge = try validatedPublicStateChallenge(prefix: prefix, cancellation: cancellation)
        try configuration.validateExistingPath()
        guard configuration.localPathResolution != nil else {
            throw DistributionError.lifecycleFailed("owner preparation requires actual selected local path resolution")
        }
        try configuration.prepareRuntimeSupport()
        let path = try ownerStateReceiptURL(prefix: prefix, configuration: configuration)
        let receiptLock = try acquireOwnerStateReceiptLock(path: path.path + ".lock", cancellation: cancellation)
        defer { _ = flock(receiptLock, LOCK_UN); close(receiptLock) }
        let service = StateUpgradeService(store: SQLiteStateStore(configuration: configuration))
        return try service.withExclusiveLifecycleFence {
            if requireEmptyIdentityAuthority,
               try SQLiteStateStore(configuration: configuration).controlIdentities.hasEstablishedIdentityAuthority() {
                throw DistributionError.lifecycleFailed("automatic owner preparation requires empty identity authority")
            }
            guard let revision = try service.verifiedRevision() else {
                throw DistributionError.lifecycleFailed("owner preparation requires initialized same-owner state")
            }
            if DistributionFileSystem.entryExists(path) {
                let previous: DistributionOwnerStateReceipt = try readStateBindingJSON(path, ownerUID: geteuid(), mode: 0o600)
                guard previous.binding.ownerUID == geteuid(), previous.binding.configuration == configuration,
                      previous.challenge.installationID == challenge.installationID else {
                    throw DistributionError.lifecycleFailed("owner receipt cannot replace an installation owner/configuration")
                }
            }
            let binding = DistributionPreparedStateBinding(schemaVersion: 1,
                installationID: challenge.installationID, preparedGeneration: challenge.generation,
                ownerUID: geteuid(), databasePath: configuration.databasePath,
                localPathResolution: configuration.localPathResolution,
                maintenancePaths: try configuration.maintenancePaths())
            let receipt = DistributionOwnerStateReceipt(schemaVersion: 1, challenge: challenge,
                binding: binding, preparedRevision: revision, receiptPath: path.path)
            guard try validatedPublicStateChallenge(prefix: prefix, cancellation: cancellation) == challenge else {
                throw DistributionError.lifecycleFailed("installed payload changed during owner preparation")
            }
            try writeCanonicalReplacing(receipt, to: path, mode: 0o600)
            return try preparedOwnerStateReceipt(prefix: prefix, configuration: configuration)
        }
    }

    public func withOwnerStateBootstrap<T>(
        prefix: URL,
        configuration: StateStoreConfiguration,
        installerIdentity: CodeIdentity,
        companionIdentity: CodeIdentity?,
        desktopIdentity: CodeIdentity?,
        _ body: (SQLiteStateStore) throws -> T
    ) throws -> T {
        guard geteuid() != 0, getuid() == geteuid() else {
            throw DistributionError.lifecycleFailed("Installed identity bootstrap requires the unprivileged state owner.")
        }
        try configuration.validateExistingPath()
        try configuration.prepareRuntimeSupport()
        let path = try ownerStateReceiptURL(prefix: prefix, configuration: configuration)
        let lock = try acquireOwnerStateReceiptLock(path: path.path + ".lock", cancellation: SecureSubprocessCancellation())
        defer { _ = flock(lock, LOCK_UN); close(lock) }
        let store = SQLiteStateStore(configuration: configuration)
        let service = StateUpgradeService(store: store)
        return try service.withExclusiveLifecycleFence {
            let challenge = try validatedPublicStateChallenge(prefix: prefix)
            let manifest: DistributionInstallManifest = try readStateBindingJSON(
                installManifestURL(prefix), ownerUID: 0, mode: 0o644)
            let selected: [(String, CodeIdentity?)] = [
                ("bin/hostwright", installerIdentity),
                ("bin/hostwright-control", companionIdentity),
                ("libexec/hostwright/Hostwright.app/Contents/MacOS/hostwright-desktop", desktopIdentity)
            ]
            for (relativePath, capturedIdentity) in selected {
                guard let capturedIdentity else { continue }
                guard manifest.files.contains(where: { $0.path == relativePath }),
                      capturedIdentity.validationMode == .installedRequirement,
                      capturedIdentity.teamIdentifier == ControlPeerTrustPolicy.installedTeamIdentifier,
                      try DarwinCurrentControlCodeIdentity.inspect(executablePath: prefix.appendingPathComponent(relativePath).path) == capturedIdentity else {
                    throw DistributionError.lifecycleFailed("Executing bootstrap code differs from the current installed generation.")
                }
            }
            let keys = try MacOSAuditSigningKeyStore(service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: store.path))
            let receiptExists = DistributionFileSystem.entryExists(path)
            try store.verifyIdentityBootstrapContinuity(keyStore: keys, requireEmptyAuthority: !receiptExists)
            if receiptExists {
                _ = try preparedOwnerStateReceipt(prefix: prefix, configuration: configuration)
            } else {
                _ = try service.migrateToLatestWithVerifiedBackup()
                guard let revision = try service.verifiedRevision(),
                      challenge == (try validatedPublicStateChallenge(prefix: prefix)),
                      let resolution = configuration.localPathResolution else {
                    throw DistributionError.lifecycleFailed("Initial owner preparation lost its exact installed state binding.")
                }
                let binding = DistributionPreparedStateBinding(schemaVersion: 1,
                    installationID: challenge.installationID, preparedGeneration: challenge.generation,
                    ownerUID: geteuid(), databasePath: configuration.databasePath,
                    localPathResolution: resolution, maintenancePaths: try configuration.maintenancePaths())
                let receipt = DistributionOwnerStateReceipt(schemaVersion: 1, challenge: challenge,
                    binding: binding, preparedRevision: revision, receiptPath: path.path)
                try validateOwnerStateReceipt(receipt, prefix: prefix)
                try writeCanonicalReplacing(receipt, to: path, mode: 0o600)
            }
            _ = try preparedOwnerStateReceipt(prefix: prefix, configuration: configuration)
            _ = try service.migrateToLatestWithVerifiedBackup()
            let result = try body(store)
            guard challenge == (try validatedPublicStateChallenge(prefix: prefix)) else {
                throw DistributionError.lifecycleFailed("Installed generation changed during identity bootstrap.")
            }
            return result
        }
    }

    public func preparedOwnerStateReceipt(
        prefix: URL,
        configuration: StateStoreConfiguration
    ) throws -> DistributionOwnerStateReceipt {
        guard geteuid() != 0 else {
            throw DistributionError.lifecycleFailed("owner configuration proof must be checked as the owner")
        }
        try configuration.validateExistingPath()
        let path = try ownerStateReceiptURL(prefix: prefix, configuration: configuration)
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(path, ownerUID: geteuid(), mode: 0o600)
        try validateOwnerStateReceipt(receipt, prefix: prefix)
        guard receipt.binding.ownerUID == geteuid(), receipt.binding.configuration == configuration,
              receipt.receiptPath == path.path,
              receipt.challenge == (try validatedPublicStateChallenge(prefix: prefix)) else {
            throw DistributionError.lifecycleFailed("owner configuration proof does not match exact selected state and payload")
        }
        return receipt
    }

    public func adoptOwnerStateReceipt(
        prefix: URL,
        receiptPath: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionOwnerStateReceipt {
        guard geteuid() == 0 else {
            throw DistributionError.lifecycleFailed("system owner receipt adoption requires root")
        }
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lock.release() }
        try refusePendingJournal(prefix)
        let status = try requiredStatus(prefix)
        var metadata = stat()
        guard lstat(receiptPath.path, &metadata) == 0, metadata.st_uid != 0 else {
            throw DistributionError.lifecycleFailed("adoption requires an explicit non-root owner receipt")
        }
        let parent = receiptPath.deletingLastPathComponent()
        var parentMetadata = stat()
        guard parent.standardizedFileURL.resolvingSymlinksInPath().path == parent.path,
              lstat(parent.path, &parentMetadata) == 0, parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == metadata.st_uid, parentMetadata.st_mode & 0o777 == 0o700 else {
            throw DistributionError.lifecycleFailed("owner receipt parent must remain a private owner directory")
        }
        try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(atPath: parent.path, role: "owner receipt parent")
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(receiptPath, ownerUID: metadata.st_uid, mode: 0o600)
        try validateOwnerStateReceipt(receipt, prefix: prefix)
        guard receipt.receiptPath == receiptPath.path, receipt.binding.ownerUID == metadata.st_uid,
              receipt.challenge.installationID == status.installationID,
              receipt.challenge.generation == status.generation,
              receipt.challenge == (try validatedPublicStateChallenge(prefix: prefix, cancellation: cancellation)),
              status.stateDatabasePath == nil || status.stateDatabasePath == receipt.binding.databasePath else {
            throw DistributionError.lifecycleFailed("owner receipt does not match current root installation generation")
        }
        let adoptedURL = lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json")
        if DistributionFileSystem.entryExists(adoptedURL) {
            let existing: DistributionOwnerStateReceipt = try readStateBindingJSON(adoptedURL, ownerUID: 0, mode: 0o600)
            guard existing.binding.ownerUID == receipt.binding.ownerUID,
                  existing.binding.configuration == receipt.binding.configuration,
                  existing.challenge.installationID == receipt.challenge.installationID else {
                throw DistributionError.lifecycleFailed("adoption cannot replace recorded owner/configuration")
            }
        }
        // Root records the cross-binding only; SQLite and Keychain remain exclusively owner operations.
        try writeCanonicalReplacing(receipt, to: adoptedURL, mode: 0o600)
        return receipt
    }

    public func probeAdoptedOwnerState(
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionOwnerStateProbeResult {
        guard geteuid() == 0 else { throw DistributionError.lifecycleFailed("owner audit-session probe requires root") }
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lock.release() }
        try refusePendingJournal(prefix)
        let status = try requiredStatus(prefix)
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(
            lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), ownerUID: 0, mode: 0o600)
        try validateOwnerStateReceipt(receipt, prefix: prefix)
        let ownerReceipt: DistributionOwnerStateReceipt = try readStateBindingJSON(
            URL(fileURLWithPath: receipt.receiptPath), ownerUID: receipt.binding.ownerUID, mode: 0o600)
        guard receipt.challenge.installationID == status.installationID, receipt.challenge.generation == status.generation,
              receipt.challenge == (try validatedPublicStateChallenge(prefix: prefix, cancellation: cancellation)),
              ownerReceipt == receipt,
              let file = status.installedManifest.files.first(where: { $0.path == "bin/hostwright-dist" }),
              try fileMatches(file, at: prefix.appendingPathComponent(file.path)) else {
            throw DistributionError.lifecycleFailed("owner probe adoption or exact executable inventory changed")
        }
        let executable = prefix.appendingPathComponent(file.path)
        let identity = try DarwinCurrentControlCodeIdentity.inspect(executablePath: executable.path)
        let request = DistributionOwnerStateProbeRequest(schemaVersion: 1, operationID: UUID().uuidString.lowercased(),
            receipt: receipt, executablePath: executable.path, executableSHA256: file.sha256, executableCodeIdentity: identity)
        try request.validate()
        let result = try SecureSubprocessRunner().run(SecureSubprocessRequest(executablePath: "/bin/launchctl",
            arguments: ["asuser", String(receipt.binding.ownerUID), executable.path, "owner-state-probe-child"],
            environment: SecureSubprocessEnvironment.minimal, workingDirectory: "/",
            standardInput: try DistributionJSON.encode(request), timeoutMilliseconds: 30_000,
            maximumStandardOutputBytes: 1_048_576, maximumStandardErrorBytes: 65_536), cancellation: cancellation)
        guard result.exitStatus == 0, result.terminationSignal == nil,
              !result.standardOutputTruncated, !result.standardErrorTruncated,
              try fileMatches(file, at: executable) else {
            throw DistributionError.lifecycleFailed("bounded signed owner audit-session probe failed before payload mutation")
        }
        let probe = try JSONDecoder().decode(DistributionOwnerStateProbeResult.self, from: result.standardOutput)
        guard probe.schemaVersion == 1, probe.operationID == request.operationID,
              probe.ownerUID == receipt.binding.ownerUID,
              probe.requestSHA256 == DistributionHash.sha256(data: try DistributionJSON.encode(request)) else {
            throw DistributionError.lifecycleFailed("owner probe reply does not match the exact root descriptor")
        }
        return probe
    }

    private func requiredRootOwnerReceipt(prefix: URL, status: DistributionInstallationStatus) throws -> DistributionOwnerStateReceipt {
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(
            lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), ownerUID: 0, mode: 0o600)
        try validateOwnerStateReceipt(receipt, prefix: prefix)
        guard receipt.challenge.installationID == status.installationID, receipt.challenge.generation == status.generation,
              receipt.challenge == (try validatedPublicStateChallenge(prefix: prefix)),
              status.stateDatabasePath == nil || status.stateDatabasePath == receipt.binding.databasePath else {
            throw DistributionError.lifecycleFailed("root adopted owner receipt does not match current generation")
        }
        let current: DistributionOwnerStateReceipt = try readStateBindingJSON(URL(fileURLWithPath: receipt.receiptPath),
            ownerUID: receipt.binding.ownerUID, mode: 0o600)
        guard current == receipt else { throw DistributionError.lifecycleFailed("owner receipt changed after root adoption") }
        return receipt
    }

    private func rootOwnerSessionKey(_ prefix: URL) -> String {
        "dev.hostwright.distribution.owner-session." + DistributionHash.sha256(data: Data(prefix.path.utf8))
    }

    private func activeRootOwnerSession(_ prefix: URL) -> DistributionOwnerStateSessionClient? {
        guard geteuid() == 0,
              let client = Thread.current.threadDictionary[rootOwnerSessionKey(prefix)] as? DistributionOwnerStateSessionClient,
              client.descriptor.receipt.challenge.prefix == prefix.path else { return nil }
        return client
    }

    private func rootOwnerPreparationPendingURL(_ prefix: URL) -> URL {
        prefix.appendingPathComponent(".hostwright-state-preparation-pending-v1.json")
    }

    private func publishPublicStateChallenge(status: DistributionInstallationStatus, prefix: URL) throws {
        let challenge = DistributionStatePreparationChallenge(schemaVersion: 1, installationID: status.installationID,
            generation: status.generation, prefix: prefix.path,
            installedManifestSHA256: try DistributionHash.sha256(fileURL: installManifestURL(prefix)))
        try challenge.validate()
        try writeCanonicalReplacing(challenge, to: statePreparationChallengeURL(prefix), mode: 0o644)
    }

    func refreshOwnerSessionReceipt(descriptor: DistributionOwnerStateSessionDescriptor,
                                    revision: StateUpgradeRevision, prior: Bool = false) throws -> DistributionOwnerStateReceipt {
        guard geteuid() == descriptor.receipt.binding.ownerUID else {
            throw DistributionError.lifecycleFailed("owner generation refresh must run after privilege drop")
        }
        let prefix = URL(fileURLWithPath: descriptor.receipt.challenge.prefix)
        let challenge = try validatedPublicStateChallenge(prefix: prefix, allowedPendingOperation: descriptor.operationID)
        let manifest = prior ? descriptor.fromManifest : descriptor.toManifest
        let generation = prior ? descriptor.fromGeneration : descriptor.toGeneration
        guard challenge.installationID == descriptor.receipt.challenge.installationID,
              challenge.generation == generation,
              challenge.installedManifestSHA256 == DistributionHash.sha256(data: try DistributionJSON.encode(manifest)) else {
            throw DistributionError.lifecycleFailed("root generation publication differs from owner operation proof")
        }
        let original = descriptor.receipt.binding
        let binding = DistributionPreparedStateBinding(schemaVersion: 1, installationID: original.installationID,
            preparedGeneration: generation, ownerUID: original.ownerUID, databasePath: original.databasePath,
            localPathResolution: original.localPathResolution, maintenancePaths: original.maintenancePaths)
        let receipt = DistributionOwnerStateReceipt(schemaVersion: 1, challenge: challenge, binding: binding,
            preparedRevision: revision, receiptPath: descriptor.receipt.receiptPath)
        try validateOwnerStateReceipt(receipt, prefix: prefix)
        try writeCanonicalReplacing(receipt, to: URL(fileURLWithPath: receipt.receiptPath), mode: 0o600)
        return receipt
    }

    private func statePreparationChallengeURL(_ prefix: URL) -> URL {
        prefix.appendingPathComponent(".hostwright-state-preparation-v1.json")
    }

    private func ownerStateReceiptURL(prefix: URL, configuration: StateStoreConfiguration) throws -> URL {
        guard let resolution = configuration.localPathResolution else {
            throw DistributionError.lifecycleFailed("owner binding requires actual local path resolution")
        }
        let parent = URL(fileURLWithPath: resolution.layout.runtimeDirectory, isDirectory: true)
        let digest = DistributionHash.sha256(data: Data(prefix.path.utf8))
        return parent.appendingPathComponent(".hostwright-owner-binding-\(digest).json")
    }

    private func validateOwnerStateReceipt(_ receipt: DistributionOwnerStateReceipt, prefix: URL) throws {
        try receipt.challenge.validate()
        let binding = receipt.binding
        try binding.configuration.validate()
        guard receipt.schemaVersion == 1, binding.schemaVersion == 1, binding.ownerUID != 0,
              binding.installationID == receipt.challenge.installationID,
              binding.preparedGeneration == receipt.challenge.generation,
              receipt.challenge.prefix == prefix.path,
              binding.configuration.databasePath == binding.databasePath,
              try binding.configuration.maintenancePaths() == binding.maintenancePaths,
              try ownerStateReceiptURL(prefix: prefix, configuration: binding.configuration).path == receipt.receiptPath,
              receipt.preparedRevision.databaseSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              receipt.preparedRevision.databaseBytes > 0,
              (0...MigrationRunner.latestSchemaVersion).contains(receipt.preparedRevision.stateSchemaVersion) else {
            throw DistributionError.lifecycleFailed("owner receipt has inconsistent installation/state binding")
        }
    }

    private func validatedPublicStateChallenge(
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation(),
        allowedPendingOperation: String? = nil
    ) throws -> DistributionStatePreparationChallenge {
        try validatePrefix(prefix)
        var metadata = stat()
        guard lstat(prefix.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == 0 || metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else {
            throw DistributionError.lifecycleFailed("state challenge prefix is not trusted")
        }
        if DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
            let pending: DistributionOwnerPreparationPending = try readStateBindingJSON(rootOwnerPreparationPendingURL(prefix),
                ownerUID: metadata.st_uid, mode: 0o644)
            guard allowedPendingOperation == pending.operationID,
                  UUID(uuidString: pending.operationID) != nil, UUID(uuidString: pending.installationID) != nil,
                  pending.toGeneration >= 2,
                  pending.toManifestSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw DistributionError.lifecycleFailed("owner preparation refuses a pending root payload operation")
            }
        }
        let challenge: DistributionStatePreparationChallenge = try readStateBindingJSON(
            statePreparationChallengeURL(prefix), ownerUID: metadata.st_uid, mode: 0o644)
        try challenge.validate()
        let manifest: DistributionInstallManifest = try readStateBindingJSON(
            installManifestURL(prefix), ownerUID: metadata.st_uid, mode: 0o644)
        try manifest.validate()
        guard challenge.prefix == prefix.path,
              challenge.installedManifestSHA256 == (try DistributionHash.sha256(fileURL: installManifestURL(prefix))) else {
            throw DistributionError.lifecycleFailed("state challenge does not match installed public manifest")
        }
        try verifyPayload(manifest, root: prefix, cancellation: cancellation)
        guard challenge.installedManifestSHA256 == (try DistributionHash.sha256(fileURL: installManifestURL(prefix))) else {
            throw DistributionError.lifecycleFailed("installed manifest changed during state challenge verification")
        }
        return challenge
    }

    private func acquireOwnerStateReceiptLock(path: String, cancellation: SecureSubprocessCancellation) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600, metadata.st_nlink == 1 else {
            close(descriptor)
            throw DistributionError.lifecycleFailed("owner binding lock is not an owned private regular file")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            if cancellation.isCancelled || DispatchTime.now().uptimeNanoseconds >= deadline {
                close(descriptor)
                throw DistributionError.lifecycleFailed("owner binding lock acquisition cancelled or timed out")
            }
            usleep(50_000)
        }
        return descriptor
    }

    private func readStateBindingJSON<T: Decodable>(_ url: URL, ownerUID: uid_t, mode: mode_t) throws -> T {
        try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(atPath: url.path, role: "state binding record")
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == ownerUID, before.st_mode & 0o777 == mode, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 1_048_576 else {
            throw DistributionError.lifecycleFailed("state binding record is not a bounded owned regular file")
        }
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        var named = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino,
              named.st_uid == ownerUID, named.st_mode == before.st_mode, named.st_nlink == 1,
              data.count == Int(before.st_size) else {
            throw DistributionError.lifecycleFailed("state binding record changed while reading")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func prepareStateBinding(
        prefix: URL,
        configuration: StateStoreConfiguration,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionPreparedStateBinding {
        try requireNotCancelled(cancellation, operation: "prepare state binding")
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try refusePendingJournal(prefix)
        try cleanupCanonicalWriteStages(prefix)
        let status = try requiredStatus(prefix)
        guard geteuid() != 0 else {
            throw DistributionError.lifecycleFailed("state binding must be prepared by the state owner, without root")
        }
        try configuration.validateExistingPath()
        if DistributionFileSystem.entryExists(stateBindingURL(prefix)) {
            let existing = try DistributionJSON.decode(DistributionPreparedStateBinding.self, from: stateBindingURL(prefix))
            guard existing.ownerUID == geteuid(), existing.installationID == status.installationID,
                  existing.configuration == configuration else {
                throw DistributionError.lifecycleFailed("prepare-state cannot replace an existing owner/configuration binding")
            }
        }
        if let bound = status.stateDatabasePath, bound != configuration.databasePath {
            throw DistributionError.lifecycleFailed("prepared state cannot change the installed database path")
        }
        let service = StateUpgradeService(store: SQLiteStateStore(configuration: configuration))
        return try service.withExclusiveLifecycleFence {
            guard try service.verifiedRevision() != nil else {
                throw DistributionError.lifecycleFailed("prepare-state requires an existing initialized database")
            }
            let binding = DistributionPreparedStateBinding(
                schemaVersion: 1, installationID: status.installationID,
                preparedGeneration: status.generation, ownerUID: geteuid(),
                databasePath: configuration.databasePath,
                localPathResolution: configuration.localPathResolution,
                maintenancePaths: try configuration.maintenancePaths()
            )
            try writeCanonicalReplacing(binding, to: stateBindingURL(prefix), mode: 0o600)
            let boundStatus = DistributionInstallationStatus(
                installationID: status.installationID, generation: status.generation,
                prefix: status.prefix, installedManifest: status.installedManifest,
                stateDatabasePath: configuration.databasePath, service: status.service,
                rollbackOperationID: status.rollbackOperationID, packageOrigin: status.packageOrigin,
                updatedAt: status.updatedAt
            )
            try writeCanonicalReplacing(boundStatus, to: statusURL(prefix), mode: 0o600)
            _ = try preparedStateBinding(prefix: prefix, configuration: configuration)
            return binding
        }
    }

    public func preparedStateBinding(
        prefix: URL,
        configuration: StateStoreConfiguration? = nil
    ) throws -> DistributionPreparedStateBinding {
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let status = try requiredStatus(prefix)
        if geteuid() == 0 {
            let receipt = try requiredRootOwnerReceipt(prefix: prefix, status: status)
            guard configuration == nil || configuration == receipt.binding.configuration else {
                throw DistributionError.lifecycleFailed("root owner binding differs from selected configuration")
            }
            return receipt.binding
        }
        return try validatePreparedStateBinding(prefix: prefix, status: status, configuration: configuration)
    }

    private func validatePreparedStateBinding(
        prefix: URL,
        status: DistributionInstallationStatus,
        configuration: StateStoreConfiguration? = nil
    ) throws -> DistributionPreparedStateBinding {
        try status.validate()
        guard status.prefix == prefix.path else {
            throw DistributionError.lifecycleFailed("state binding status belongs to another prefix")
        }
        guard try inspectOwnedRegularFile(stateBindingURL(prefix), expectedMode: 0o600, computeDigest: false) != nil else {
            throw DistributionError.lifecycleFailed("prepared state receipt is not an owned private file")
        }
        let binding = try DistributionJSON.decode(DistributionPreparedStateBinding.self, from: stateBindingURL(prefix))
        guard binding.schemaVersion == 1,
              binding.ownerUID == geteuid(), binding.ownerUID != 0,
              binding.installationID == status.installationID,
              binding.databasePath == status.stateDatabasePath,
              binding.configuration.databasePath == binding.databasePath,
              try binding.configuration.maintenancePaths() == binding.maintenancePaths,
              configuration == nil || configuration == binding.configuration else {
            throw DistributionError.lifecycleFailed("prepared state binding does not match the exact owner/configuration")
        }
        try binding.configuration.validateProspectivePath()
        return binding
    }

    private func verifiedNativeRollbackIdentities(root: URL, manifest: DistributionInstallManifest) -> [CodeIdentity] {
        let paths: [(String, Set<String>)] = [
            ("bin/hostwright", ["hostwright", "dev.hostwright.cli"]),
            ("bin/hostwright-control", ["hostwright-control"]),
            (DistributionLayout.desktopExecutablePath, ["dev.hostwright.desktop"])
        ]
        return paths.compactMap { path, identifiers in
            guard let file = manifest.files.first(where: { $0.path == path }),
                  (try? fileMatches(file, at: root.appendingPathComponent(path))) == true,
                  let identity = try? DarwinCurrentControlCodeIdentity.inspect(executablePath: root.appendingPathComponent(path).path),
                  identity.validationMode == .installedRequirement,
                  identifiers.contains(identity.signingIdentifier),
                  (try? fileMatches(file, at: root.appendingPathComponent(path))) == true else { return nil }
            return identity
        }
    }

    private func stateBindingURL(_ prefix: URL) -> URL {
        lifecycleRoot(prefix).appendingPathComponent("prepared-state-v1.json")
    }

    private func lifecycleStore(path: String, prefix: URL) throws -> SQLiteStateStore {
        if DistributionFileSystem.entryExists(stateBindingURL(prefix)) {
            let status: DistributionInstallationStatus
            if let journal = try loadOptional(DistributionLifecycleJournal.self, from: journalURL(prefix)),
               let recorded = try loadOptional(DistributionInstallationStatus.self, from: statusURL(prefix)),
               let prior = journal.priorStatus,
               prior.service == journal.serviceBefore,
               replacingServiceState(in: recorded, with: journal.serviceBefore) == prior {
                try journal.validate()
                guard journal.prefix == prefix.path else {
                    throw DistributionError.lifecycleFailed("state fence journal belongs to another prefix")
                }
                status = recorded
            } else { status = try requiredStatus(prefix) }
            let binding = try validatePreparedStateBinding(prefix: prefix, status: status)
            guard binding.databasePath == path else {
                throw DistributionError.lifecycleFailed("state operation is outside the prepared binding")
            }
            return SQLiteStateStore(configuration: binding.configuration)
        }
        let resolution = try HostwrightLocalPathResolver.resolve(environment: [:])
        if resolution.stateDatabasePath == path {
            return SQLiteStateStore(configuration: StateStoreConfiguration(localPathResolution: resolution))
        }
        return SQLiteStateStore(path: path)
    }

    public func adoptLegacyInstallation(
        prefix: URL,
        stateDatabasePath: String? = nil,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionInstallationStatus {
        try requireNotCancelled(cancellation, operation: "legacy adoption preflight")
        try validatePrefix(prefix)
        let manifestURL = installManifestURL(prefix)
        let legacyManifest = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: manifestURL
        )
        try legacyManifest.validate()
        guard legacyManifest.schemaVersion == 1 else {
            throw DistributionError.lifecycleFailed(
                "only a verified schema-1 installation can use legacy adoption"
            )
        }
        let selectedStatePath = try selectedStatePath(
            requested: stateDatabasePath,
            existingStatus: nil
        )
        if let selectedStatePath,
           DistributionFileSystem.entryExists(URL(fileURLWithPath: selectedStatePath)) {
            _ = try withStateLifecycleBoundary("verify the legacy installation state database") {
                try MigrationRunner().compatibleSchemaVersion(
                    in: lifecycleStore(path: selectedStatePath, prefix: prefix)
                )
            }
        }
        try verifyInstalledExecutableContracts(
            prefix: prefix,
            manifest: legacyManifest,
            cancellation: cancellation
        )
        let serviceState = try captureManagedServiceState(
            prefix: prefix,
            cancellation: cancellation
        )

        let foundationExisted = DistributionFileSystem.entryExists(lifecycleRoot(prefix))
        try ensureFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        var committed = false
        defer {
            lifecycleLock.release()
            if !committed, !foundationExisted {
                try? removeFoundationIfUninstalled(prefix)
            }
        }
        try cleanupCanonicalWriteStages(prefix)
        try refusePendingJournal(prefix)
        guard !DistributionFileSystem.entryExists(statusURL(prefix)) else {
            throw DistributionError.lifecycleFailed("durable lifecycle status already exists")
        }
        let lockedManifest = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: manifestURL
        )
        guard lockedManifest == legacyManifest else {
            throw DistributionError.installOwnershipMismatch(
                DistributionLayout.installManifestFileName
            )
        }
        try verifyInstalledExecutableContracts(
            prefix: prefix,
            manifest: lockedManifest,
            cancellation: cancellation
        )
        let status = DistributionInstallationStatus(
            installationID: UUID().uuidString.lowercased(),
            generation: 1,
            prefix: prefix.path,
            installedManifest: lockedManifest,
            stateDatabasePath: selectedStatePath,
            service: serviceState,
            rollbackOperationID: nil,
            updatedAt: DistributionTimestamp.string(Date())
        )
        try status.validate()
        try writeCanonicalReplacing(status, to: statusURL(prefix), mode: 0o600)
        guard try requiredStatus(prefix) == status else {
            throw DistributionError.lifecycleFailed("legacy adoption status verification failed")
        }
        committed = true
        return status
    }

    public func install(
        artifact: VerifiedDistributionArtifact,
        prefix: URL,
        stateDatabasePath: String? = nil,
        requiredOperation: DistributionLifecycleOperation? = nil,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionInstallationStatus {
        try install(
            manifest: artifact.manifest,
            sourceRoot: artifact.extractedRoot,
            prefix: prefix,
            stateDatabasePath: stateDatabasePath,
            requiredOperation: requiredOperation,
            packageOrigin: nil,
            cancellation: cancellation
        )
    }

    public func install(
        artifact: VerifiedTrustedReleaseArtifact,
        prefix: URL,
        stateDatabasePath: String? = nil,
        requiredOperation: DistributionLifecycleOperation? = nil,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionInstallationStatus {
        try install(
            manifest: artifact.manifest,
            sourceRoot: artifact.extractedRoot,
            prefix: prefix,
            stateDatabasePath: stateDatabasePath,
            requiredOperation: requiredOperation,
            packageOrigin: nil,
            cancellation: cancellation
        )
    }

    func installPackage(
        manifest: DistributionArtifactManifest,
        sourceRoot: URL,
        prefix: URL,
        requiredOperation: DistributionLifecycleOperation,
        packageOrigin: DistributionPackageOrigin,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionInstallationStatus {
        try packageOrigin.validate()
        guard try DistributionPackageVersion.make(from: manifest.packageVersion)
            == packageOrigin.packageVersion,
              packageOrigin.packageVersion
                == packageOrigin.mostRecentPackageReceiptVersion,
              !packageOrigin.pendingReceiptCleanup else {
            throw DistributionError.lifecycleFailed(
                "package origin is not bound to the candidate manifest and current receipt"
            )
        }
        return try install(
            manifest: manifest,
            sourceRoot: sourceRoot,
            prefix: prefix,
            stateDatabasePath: nil,
            requiredOperation: requiredOperation,
            packageOrigin: packageOrigin,
            cancellation: cancellation
        )
    }

    private func install(
        manifest: DistributionArtifactManifest,
        sourceRoot: URL,
        prefix: URL,
        stateDatabasePath: String?,
        requiredOperation: DistributionLifecycleOperation?,
        packageOrigin: DistributionPackageOrigin?,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionInstallationStatus {
        try requireNotCancelled(cancellation, operation: "installed lifecycle preflight")
        try manifest.validate()
        try validatePrefix(prefix)
        let foundationExisted = DistributionFileSystem.entryExists(lifecycleRoot(prefix))
        try ensureFoundation(prefix)
        defer {
            if !foundationExisted {
                try? removeFoundationIfUninstalled(prefix)
            }
        }
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try cleanupCanonicalWriteStages(prefix)
        try refusePendingJournal(prefix)

        let manifestURL = installManifestURL(prefix)
        let existingManifest = try loadOptional(DistributionInstallManifest.self, from: manifestURL)
        let existingStatus = try loadOptional(
            DistributionInstallationStatus.self,
            from: statusURL(prefix)
        )
        if let existingManifest {
            try existingManifest.validate()
            guard let existingStatus else {
                throw DistributionError.lifecycleFailed(
                    "an install manifest exists without durable lifecycle status; run an explicit legacy-adoption workflow"
                )
            }
            try existingStatus.validate()
            guard existingStatus.prefix == prefix.path,
                  existingStatus.installedManifest == existingManifest else {
                throw DistributionError.lifecycleFailed(
                    "installed manifest and lifecycle status do not describe the same generation"
                )
            }
        } else {
            guard existingStatus == nil else {
                throw DistributionError.lifecycleFailed("lifecycle status exists without an installed manifest")
            }
            for path in DistributionLayout.payloadModes.keys {
                guard !DistributionFileSystem.entryExists(prefix.appendingPathComponent(path)) else {
                    throw DistributionError.installOwnershipMismatch(path)
                }
            }
        }

        let operation: DistributionLifecycleOperation
        if let existingManifest {
            operation = switch try DistributionVersionTransition.classify(
                installedVersion: existingManifest.packageVersion,
                installedCommit: existingManifest.sourceCommit,
                candidateVersion: manifest.packageVersion,
                candidateCommit: manifest.sourceCommit
            ) {
            case .upgrade: .upgrade
            case .repair: .repair
            }
            if operation == .upgrade,
               existingStatus?.packageOrigin != nil,
               packageOrigin == nil {
                throw DistributionError.versionConflict(
                    "Package-managed installations must be upgraded with hostwright-dist package-apply."
                )
            }
            if operation == .upgrade {
                try verifyOwnedFiles(existingManifest, prefix: prefix, cancellation: cancellation)
            } else {
                try validateRepairableOwnedPaths(existingManifest, prefix: prefix)
            }
        } else {
            operation = .install
        }
        if let requiredOperation {
            guard [.install, .upgrade, .repair].contains(requiredOperation),
                  operation == requiredOperation else {
                throw DistributionError.versionConflict(
                    "Requested \(requiredOperation.rawValue), but the locked installation state requires \(operation.rawValue)."
                )
            }
        }

        let rootReceipt: DistributionOwnerStateReceipt?
        if geteuid() == 0, let existingStatus,
           DistributionFileSystem.entryExists(lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json")) {
            rootReceipt = try requiredRootOwnerReceipt(prefix: prefix, status: existingStatus)
        } else { rootReceipt = nil }
        if let stateDatabasePath, let rootReceipt, stateDatabasePath != rootReceipt.binding.databasePath {
            throw DistributionError.lifecycleFailed("root package cannot select another owner database")
        }
        let selectedStatePath = try selectedStatePath(
            requested: stateDatabasePath ?? rootReceipt?.binding.databasePath,
            existingStatus: existingStatus
        )
        if operation == .upgrade {
            let binding = try preparedStateBinding(prefix: prefix)
            guard binding.preparedGeneration == existingStatus?.generation,
                  binding.databasePath == selectedStatePath else {
                throw DistributionError.lifecycleFailed("upgrade requires prepare-state for the current generation")
            }
        }
        if geteuid() != 0, let selectedStatePath, DistributionFileSystem.entryExists(URL(fileURLWithPath: selectedStatePath)) {
            _ = try withStateLifecycleBoundary("verify the installation state database") {
                try MigrationRunner().compatibleSchemaVersion(
                    in: lifecycleStore(path: selectedStatePath, prefix: prefix)
                )
            }
        }
        let serviceState = try captureManagedServiceState(
            prefix: prefix,
            cancellation: cancellation
        )
        let operationStatus = existingStatus.map {
            replacingServiceState(in: $0, with: serviceState)
        }

        let createdDirectories = Array(
            Set(existingManifest?.createdDirectories ?? [])
                .union(directoriesCreatedByInstalling(manifest.files, prefix: prefix))
        ).sorted()
        let targetManifest = DistributionInstallManifest(
            artifact: manifest,
            createdDirectories: createdDirectories
        )
        try targetManifest.validate()
        return try performTransition(
            operation: operation,
            sourceRoot: sourceRoot,
            fromManifest: existingManifest,
            toManifest: targetManifest,
            existingStatus: operationStatus,
            serviceBefore: serviceState,
            prefix: prefix,
            stateDatabasePath: selectedStatePath,
            targetStateSnapshot: nil,
            authorizedRollbackOperationID: nil,
            packageOrigin: packageOrigin,
            cancellation: cancellation
        )
    }

    public func inspect(prefix: URL) throws -> DistributionLifecycleInspection {
        try inspect(prefix: prefix, verifyPackageReceipt: true)
    }

    func inspectForPackageApply(prefix: URL) throws -> DistributionLifecycleInspection {
        try inspect(prefix: prefix, verifyPackageReceipt: false)
    }

    private func inspect(
        prefix: URL,
        verifyPackageReceipt: Bool
    ) throws -> DistributionLifecycleInspection {
        try validatePrefix(prefix)
        let root = lifecycleRoot(prefix)
        guard DistributionFileSystem.entryExists(root) else {
            let manifestExists = DistributionFileSystem.entryExists(installManifestURL(prefix))
            if manifestExists {
                throw DistributionError.lifecycleFailed(
                    "installed manifest exists without lifecycle ownership metadata; run explicit hostwright-dist adopt-legacy"
                )
            }
            return DistributionLifecycleInspection(
                readiness: .notInstalled,
                status: nil,
                pendingOperation: nil
            )
        }
        try validateFoundation(prefix)
        let cancellation = SecureSubprocessCancellation()
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        let status = try loadOptional(DistributionInstallationStatus.self, from: statusURL(prefix))
        try status?.validate()
        let journal = try loadOptional(DistributionLifecycleJournal.self, from: journalURL(prefix))
        try journal?.validate()
        if let journal, journal.prefix != prefix.path {
            throw DistributionError.lifecycleFailed("pending lifecycle journal belongs to another prefix")
        }
        if journal != nil || hasCanonicalWriteStage(prefix) || DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) {
            return DistributionLifecycleInspection(
                readiness: .recoveryRequired,
                status: status,
                pendingOperation: journal
            )
        }
        guard let status else {
            if DistributionFileSystem.entryExists(installManifestURL(prefix)) {
                throw DistributionError.lifecycleFailed(
                    "a legacy install manifest requires explicit hostwright-dist adopt-legacy"
                )
            }
            return DistributionLifecycleInspection(
                readiness: .notInstalled,
                status: nil,
                pendingOperation: nil
            )
        }
        let installedManifest = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: installManifestURL(prefix)
        )
        guard installedManifest == status.installedManifest else {
            throw DistributionError.lifecycleFailed(
                "installed manifest does not match lifecycle status"
            )
        }
        if verifyPackageReceipt, let origin = status.packageOrigin {
            let receipt = try packageReceiptController.receipt(
                identifier: origin.packageIdentifier,
                cancellation: SecureSubprocessCancellation()
            )
            guard receipt?.identifier == origin.packageIdentifier,
                  receipt?.version == origin.mostRecentPackageReceiptVersion else {
                throw DistributionError.installOwnershipMismatch("package receipt")
            }
        }
        return DistributionLifecycleInspection(readiness: .ready, status: status, pendingOperation: nil)
    }

    public func recover(
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionRecoveryResult {
        try requireNotCancelled(cancellation, operation: "lifecycle recovery preflight")
        try validatePrefix(prefix)
        guard DistributionFileSystem.entryExists(lifecycleRoot(prefix)) else {
            return DistributionRecoveryResult(action: .noAction, operationID: nil, status: nil)
        }
        try validateFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try cleanupCanonicalWriteStages(prefix)
        if DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) {
            return try completeTerminalCleanup(prefix: prefix)
        }
        guard let journal = try loadOptional(
            DistributionLifecycleJournal.self,
            from: journalURL(prefix)
        ) else {
            let status = try loadOptional(DistributionInstallationStatus.self, from: statusURL(prefix))
            try status?.validate()
            if geteuid() == 0, DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
                let pending: DistributionOwnerPreparationPending = try readStateBindingJSON(rootOwnerPreparationPendingURL(prefix), ownerUID: 0, mode: 0o644)
                guard let status, pending.installationID == status.installationID else {
                    throw DistributionError.lifecycleFailed("orphan owner-preparation marker does not match completed root installation")
                }
                let manifestSHA256 = DistributionHash.sha256(data: try DistributionJSON.encode(status.installedManifest))
                guard (status.generation == pending.toGeneration && manifestSHA256 == pending.toManifestSHA256) ||
                      (status.generation == pending.fromGeneration && manifestSHA256 == pending.fromManifestSHA256) else {
                    throw DistributionError.lifecycleFailed("orphan owner-preparation marker does not match completed root generation")
                }
                try verifyOwnedFiles(status.installedManifest, prefix: prefix)
                try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644)
            }
            if status == nil {
                try removeFoundationIfUninstalled(prefix)
            }
            return DistributionRecoveryResult(action: .noAction, operationID: nil, status: status)
        }
        try journal.validate()
        guard journal.prefix == prefix.path else {
            throw DistributionError.lifecycleFailed("pending lifecycle journal belongs to another prefix")
        }
        let status = try loadOptional(DistributionInstallationStatus.self, from: statusURL(prefix))
        if journal.checkpoint == .compensationPublished {
            try withJournalStateFence(journal, operation: "finalize recovered prior generation") {
                try finalizeCompletedCompensation(journal: journal, prefix: prefix)
            }
            return DistributionRecoveryResult(
                action: journal.fromManifest == nil
                    ? .removedInterruptedInitialInstall
                    : .restoredPriorGeneration,
                operationID: journal.operationID,
                status: journal.priorStatus
            )
        }
        if journal.operation == .uninstall, journal.checkpoint == .statusPublished {
            try finalizeCommittedUninstall(
                journal: journal,
                prefix: prefix,
                cancellation: cancellation
            )
            return DistributionRecoveryResult(
                action: .completedUninstall,
                operationID: journal.operationID,
                status: nil
            )
        }
        if journal.checkpoint == .statusPublished {
            guard let status,
                  status.installedManifest == journal.toManifest,
                  status.generation == (journal.priorStatus?.generation ?? 0) + 1 else {
                throw DistributionError.lifecycleFailed(
                    "published lifecycle status is not bound to the pending committed generation"
                )
            }
            try withJournalStateFence(journal, operation: "finalize the committed lifecycle transition") {
                try verifyInstalledExecutableContracts(
                    prefix: prefix,
                    manifest: status.installedManifest,
                    cancellation: cancellation
                )
                if status.service != .notInstalled, journal.ownerStateDescriptorSHA256 == nil {
                    try restoreManagedService(
                        to: status.service,
                        prefix: prefix,
                        cancellation: cancellation
                    )
                }
            }
            if status.service != .notInstalled, journal.ownerStateDescriptorSHA256 != nil {
                try restoreManagedService(to: status.service, prefix: prefix, cancellation: cancellation)
            }
            try finalizePublishedTransition(journal: journal, prefix: prefix)
            if geteuid() == 0, DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
                try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644)
            }
            return DistributionRecoveryResult(
                action: .completedPublishedGeneration,
                operationID: journal.operationID,
                status: status
            )
        }
        try withJournalStateFence(journal, operation: "recover the prior lifecycle generation") {
            try compensate(journal: journal, prefix: prefix)
        }
        return DistributionRecoveryResult(
            action: journal.fromManifest == nil
                ? .removedInterruptedInitialInstall
                : .restoredPriorGeneration,
            operationID: journal.operationID,
            status: journal.priorStatus
        )
    }

    public func rollback(
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionInstallationStatus {
        try requireNotCancelled(cancellation, operation: "verified rollback preflight")
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try cleanupCanonicalWriteStages(prefix)
        try refusePendingJournal(prefix)
        let recordedStatus = try requiredStatus(prefix)
        guard recordedStatus.stateDatabasePath != nil else {
            throw DistributionError.lifecycleFailed("rollback requires state bound before upgrade; run prepare-state before upgrading")
        }
        _ = try preparedStateBinding(prefix: prefix)
        guard let rollbackOperationID = recordedStatus.rollbackOperationID else {
            throw DistributionError.lifecycleFailed("no verified rollback generation is available")
        }
        try verifyOwnedFiles(recordedStatus.installedManifest, prefix: prefix, cancellation: cancellation)
        let serviceState = try captureManagedServiceState(
            prefix: prefix,
            cancellation: cancellation
        )
        let status = replacingServiceState(in: recordedStatus, with: serviceState)
        let rollbackURL = transactionURL(prefix, operationID: rollbackOperationID)
            .appendingPathComponent(DistributionLayout.lifecycleRollbackFileName)
        let record = try DistributionJSON.decode(DistributionRollbackRecord.self, from: rollbackURL)
        try record.validate()
        guard record.operationID == rollbackOperationID,
              record.installedManifest == status.installedManifest,
              record.priorGeneration + 1 == status.generation else {
            throw DistributionError.lifecycleFailed("rollback record does not authorize the installed generation")
        }
        let sourceRoot = prefix.appendingPathComponent(record.backupRelativePath)
        try verifyPayload(record.priorManifest, root: sourceRoot, cancellation: cancellation)
        let targetSnapshot: StateUpgradeSnapshot?
        if let snapshot = record.stateSnapshot {
            targetSnapshot = StateUpgradeSnapshot(
                databasePath: snapshot.databasePath,
                snapshotPath: snapshot.ownerSnapshotPath ?? prefix.appendingPathComponent(snapshot.snapshotRelativePath).path,
                databaseSHA256: snapshot.databaseSHA256,
                databaseBytes: snapshot.databaseBytes,
                stateSchemaVersion: snapshot.stateSchemaVersion
            )
            if geteuid() != 0 {
                try withStateLifecycleBoundary("verify the rollback state snapshot") {
                    try StateUpgradeService(store: lifecycleStore(path: snapshot.databasePath, prefix: prefix))
                        .verify(targetSnapshot!)
                }
            }
        } else {
            targetSnapshot = nil
        }
        var rollbackPackageOrigin = record.priorPackageOrigin
        if let priorOrigin = rollbackPackageOrigin,
           let currentOrigin = status.packageOrigin,
           DistributionPackageVersion.compare(
            priorOrigin.mostRecentPackageReceiptVersion,
            currentOrigin.mostRecentPackageReceiptVersion
           ) == .orderedAscending {
            rollbackPackageOrigin = priorOrigin.replacing(
                mostRecentPackageReceiptVersion: currentOrigin.mostRecentPackageReceiptVersion
            )
        }
        let result = try performTransition(
            operation: .rollback,
            sourceRoot: sourceRoot,
            fromManifest: status.installedManifest,
            toManifest: record.priorManifest,
            existingStatus: status,
            serviceBefore: serviceState,
            prefix: prefix,
            stateDatabasePath: status.stateDatabasePath,
            targetStateSnapshot: targetSnapshot,
            authorizedRollbackOperationID: rollbackOperationID,
            packageOrigin: rollbackPackageOrigin,
            cancellation: cancellation
        )
        try removeTransaction(prefix, operationID: rollbackOperationID)
        return result
    }

    public func uninstallPlan(
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionUninstallPlan {
        try requireNotCancelled(cancellation, operation: "uninstall plan preflight")
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try refuseCanonicalWriteStage(prefix)
        try refusePendingJournal(prefix)
        let status = try requiredStatus(prefix)
        if dataPolicy == .remove, status.packageOrigin != nil {
            throw DistributionError.invalidArguments(
                DistributionPackagePolicy.removeDataUnsupportedMessage
            )
        }
        try verifyOwnedFiles(status.installedManifest, prefix: prefix, cancellation: cancellation)
        if dataPolicy == .preserve {
            let stateExists = status.stateDatabasePath.map {
                DistributionFileSystem.entryExists(URL(fileURLWithPath: $0))
            } ?? false
            return try makeUninstallPlan(
                status: status,
                dataPolicy: dataPolicy,
                stateDatabaseExists: stateExists,
                stateRevision: nil
            )
        }
        if let statePath = status.stateDatabasePath {
            return try withStateLifecycleBoundary("create the verified uninstall state revision") {
                let stateService = try StateUpgradeService(store: lifecycleStore(path: statePath, prefix: prefix))
                return try stateService.withExclusiveLifecycleFence {
                    let revision = try stateService.verifiedRevision()
                    return try makeUninstallPlan(
                        status: status,
                        dataPolicy: dataPolicy,
                        stateDatabaseExists: revision != nil,
                        stateRevision: revision
                    )
                }
            }
        }
        return try makeUninstallPlan(
            status: status,
            dataPolicy: dataPolicy,
            stateDatabaseExists: false,
            stateRevision: nil
        )
    }

    public func uninstall(
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy = .preserve,
        confirmationToken: String? = nil,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> DistributionUninstallResult {
        try uninstall(
            prefix: prefix,
            dataPolicy: dataPolicy,
            confirmationToken: confirmationToken,
            packageReceiptCleanup: false,
            cancellation: cancellation
        )
    }

    func uninstallPackage(
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy,
        confirmationToken: String?,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionUninstallResult {
        try uninstall(
            prefix: prefix,
            dataPolicy: dataPolicy,
            confirmationToken: confirmationToken,
            packageReceiptCleanup: true,
            cancellation: cancellation
        )
    }

    private func uninstall(
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy,
        confirmationToken: String?,
        packageReceiptCleanup: Bool,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionUninstallResult {
        try requireNotCancelled(cancellation, operation: "uninstall preflight")
        try validatePrefix(prefix)
        try validateFoundation(prefix)
        let lifecycleLock = try DistributionLifecycleFileLock(prefix: prefix, cancellation: cancellation)
        defer { lifecycleLock.release() }
        try cleanupCanonicalWriteStages(prefix)
        try refusePendingJournal(prefix)
        let recordedStatus = try requiredStatus(prefix)
        if !packageReceiptCleanup, recordedStatus.packageOrigin != nil {
            throw DistributionError.versionConflict(
                "Package-managed installations must be removed with hostwright-dist package-uninstall."
            )
        }
        try verifyOwnedFiles(recordedStatus.installedManifest, prefix: prefix, cancellation: cancellation)
        let serviceState = try captureManagedServiceState(
            prefix: prefix,
            cancellation: cancellation
        )
        let status = replacingServiceState(in: recordedStatus, with: serviceState)
        if packageReceiptCleanup {
            guard let origin = status.packageOrigin,
                  !origin.pendingReceiptCleanup else {
                throw DistributionError.installOwnershipMismatch(
                    "package lifecycle origin"
                )
            }
        }
        switch dataPolicy {
        case .preserve:
            guard confirmationToken == nil else {
                throw DistributionError.invalidArguments(
                    "preserve-data uninstall does not accept a removal confirmation token"
                )
            }
            return try performUninstall(
                status: status,
                prefix: prefix,
                dataPolicy: dataPolicy,
                stateService: nil,
                packageReceiptCleanup: packageReceiptCleanup,
                cancellation: cancellation
            )
        case .remove:
            guard let statePath = status.stateDatabasePath else {
                throw DistributionError.lifecycleFailed(
                    "managed-data removal requires an installation-bound state database"
                )
            }
            return try withStateLifecycleBoundary("perform the fenced managed-data uninstall") {
                let stateService = try StateUpgradeService(store: lifecycleStore(path: statePath, prefix: prefix))
                return try stateService.withExclusiveLifecycleFence {
                    let revision = try stateService.verifiedRevision()
                    let plan = try makeUninstallPlan(
                        status: status,
                        dataPolicy: dataPolicy,
                        stateDatabaseExists: revision != nil,
                        stateRevision: revision
                    )
                    guard confirmationToken == plan.confirmationToken else {
                        throw DistributionError.lifecycleFailed(
                            "managed-data removal requires the exact current uninstall-plan confirmation token"
                        )
                    }
                    return try performUninstall(
                        status: status,
                        prefix: prefix,
                        dataPolicy: dataPolicy,
                        stateService: stateService,
                        packageReceiptCleanup: packageReceiptCleanup,
                        cancellation: cancellation
                    )
                }
            }
        }
    }

    private func performUninstall(
        status: DistributionInstallationStatus,
        prefix: URL,
        dataPolicy: DistributionUninstallDataPolicy,
        stateService: StateUpgradeService?,
        packageReceiptCleanup: Bool,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionUninstallResult {
        let operationID = UUID().uuidString.lowercased()
        let journal = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .uninstall,
            checkpoint: .intentRecorded,
            prefix: prefix.path,
            transactionRelativePath: transactionRelativePath(operationID),
            fromManifest: status.installedManifest,
            toManifest: nil,
            stateSnapshot: nil,
            serviceBefore: status.service,
            dataPolicy: dataPolicy,
            startedAt: DistributionTimestamp.string(Date()),
            priorStatus: status,
            packageReceiptCleanup: packageReceiptCleanup ? true : nil
        )
        try writeJournal(journal, prefix: prefix)
        try checkpointReached(.intentRecorded, cancellation: cancellation)
        let transaction = try createTransaction(prefix, operationID: operationID)
        let backup = transaction.appendingPathComponent("backup", isDirectory: true)
        try DistributionFileSystem.createExclusiveDirectory(backup)
        try backupInstalledPayload(
            status.installedManifest,
            prefix: prefix,
            backup: backup,
            cancellation: cancellation
        )
        var currentJournal = journal.replacing(checkpoint: .priorPayloadBackedUp)
        try writeJournal(currentJournal, prefix: prefix)
        try checkpointReached(.priorPayloadBackedUp, cancellation: cancellation)

        if dataPolicy == .remove, let stateService,
           DistributionFileSystem.entryExists(URL(fileURLWithPath: stateService.store.path)) {
            let stateDirectory = transaction.appendingPathComponent("state", isDirectory: true)
            try DistributionFileSystem.createExclusiveDirectory(stateDirectory)
            let snapshot = try stateService.createVerifiedSnapshot(
                at: stateDirectory.appendingPathComponent("state.sqlite").path
            )
            let snapshotRecord = DistributionStateSnapshotRecord(
                databasePath: snapshot.databasePath,
                snapshotRelativePath: "\(transactionRelativePath(operationID))/state/state.sqlite",
                databaseSHA256: snapshot.databaseSHA256,
                databaseBytes: snapshot.databaseBytes,
                stateSchemaVersion: snapshot.stateSchemaVersion
            )
            currentJournal = currentJournal.replacing(
                checkpoint: .stateBackedUp,
                stateSnapshot: snapshotRecord
            )
            try writeJournal(currentJournal, prefix: prefix)
            try checkpointReached(.stateBackedUp, cancellation: cancellation)
        }
        if status.service != .notInstalled {
            try stopManagedService(
                capturedState: status.service,
                prefix: prefix,
                cancellation: cancellation
            )
            currentJournal = currentJournal.replacing(checkpoint: .serviceStopped)
            try writeJournal(currentJournal, prefix: prefix)
            try checkpointReached(.serviceStopped, cancellation: cancellation)
        }
        currentJournal = currentJournal.replacing(checkpoint: .payloadPublishing)
        try writeJournal(currentJournal, prefix: prefix)
        try checkpointReached(.payloadPublishing, cancellation: cancellation)

        var uninstallCommitted = false
        do {
            for file in status.installedManifest.files {
                try requireNotCancelled(cancellation, operation: "remove installed payload")
                try removeExactOwnedFile(prefix.appendingPathComponent(file.path))
            }
            try requireNotCancelled(cancellation, operation: "remove install manifest")
            try removeExactOwnedFile(installManifestURL(prefix))
            let removedDirectories = try removeCreatedDirectoriesIfEmpty(
                status.installedManifest.createdDirectories,
                prefix: prefix
            )
            currentJournal = currentJournal.replacing(checkpoint: .payloadPublished)
            try writeJournal(currentJournal, prefix: prefix)
            try checkpointReached(.payloadPublished, cancellation: cancellation)

            var removedStatePaths: [String] = []
            if dataPolicy == .remove, let stateService,
               DistributionFileSystem.entryExists(URL(fileURLWithPath: stateService.store.path)) {
                currentJournal = currentJournal.replacing(checkpoint: .stateMigrating)
                try writeJournal(currentJournal, prefix: prefix)
                try checkpointReached(.stateMigrating, cancellation: cancellation)
                try requireNotCancelled(cancellation, operation: "remove verified state database")
                let stateRemoval = try StateDatabaseRemovalService(store: stateService.store)
                    .removeVerifiedDatabase()
                removedStatePaths = stateRemoval.removedPaths
                currentJournal = currentJournal.replacing(checkpoint: .stateMigrated)
                try writeJournal(currentJournal, prefix: prefix)
                try checkpointReached(.stateMigrated, cancellation: cancellation)
            }

            let removed = (status.installedManifest.files.map(\.path)
                + [DistributionLayout.installManifestFileName]
                + removedDirectories).sorted()
            if packageReceiptCleanup {
                guard let origin = status.packageOrigin else {
                    throw DistributionError.lifecycleFailed(
                        "package receipt cleanup lost its package origin"
                    )
                }
                let pendingStatus = replacingPackageOrigin(
                    in: status,
                    with: origin.replacing(pendingReceiptCleanup: true)
                )
                try pendingStatus.validate()
                try writeCanonicalReplacing(
                    pendingStatus,
                    to: statusURL(prefix),
                    mode: 0o600
                )
            }
            currentJournal = currentJournal.replacing(checkpoint: .statusPublished)
            try writeJournal(currentJournal, prefix: prefix)
            uninstallCommitted = true
            try checkpointReached(.statusPublished, cancellation: cancellation)
            try finalizeCommittedUninstall(
                journal: currentJournal,
                prefix: prefix,
                cancellation: cancellation
            )
            return DistributionUninstallResult(
                dataPolicy: dataPolicy,
                removedPaths: removed,
                removedStatePaths: removedStatePaths,
                preservedStateDatabasePath: dataPolicy == .preserve
                    ? status.stateDatabasePath
                    : nil
            )
        } catch let interruption as DistributionLifecycleInterruption {
            throw interruption
        } catch {
            let primary = error
            if uninstallCommitted {
                throw primary
            }
            do {
                try compensate(journal: currentJournal, prefix: prefix)
            } catch {
                throw DistributionError.lifecycleFailed(
                    "uninstall failed and exact prior installation recovery also failed"
                )
            }
            throw primary
        }
    }

    private func makeUninstallPlan(
        status: DistributionInstallationStatus,
        dataPolicy: DistributionUninstallDataPolicy,
        stateDatabaseExists: Bool,
        stateRevision: StateUpgradeRevision?
    ) throws -> DistributionUninstallPlan {
        let components = [
            "hostwright-uninstall-plan-v1",
            status.prefix,
            status.installationID,
            String(status.generation),
            status.updatedAt,
            dataPolicy.rawValue,
            status.stateDatabasePath ?? "no-state-database",
            stateDatabaseExists ? "state-present" : "state-absent",
            stateRevision?.databaseSHA256 ?? "no-state-digest",
            stateRevision.map { String($0.databaseBytes) } ?? "no-state-bytes",
            stateRevision.map { String($0.stateSchemaVersion) } ?? "no-state-schema"
        ]
        let token = DistributionHash.sha256(
            data: Data(components.joined(separator: "\u{1f}").utf8)
        )
        let plan = DistributionUninstallPlan(
            prefix: status.prefix,
            installationID: status.installationID,
            generation: status.generation,
            dataPolicy: dataPolicy,
            stateDatabasePath: status.stateDatabasePath,
            stateDatabaseExists: stateDatabaseExists,
            stateRevision: stateRevision,
            confirmationToken: token,
            createdAt: DistributionTimestamp.string(Date())
        )
        try plan.validate()
        return plan
    }

    private func finalizeCommittedUninstall(
        journal: DistributionLifecycleJournal,
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard journal.operation == .uninstall,
              journal.checkpoint == .statusPublished,
              let manifest = journal.fromManifest else {
            throw DistributionError.lifecycleFailed(
                "committed uninstall finalization requires its durable uninstall journal"
            )
        }
        for file in manifest.files {
            guard !DistributionFileSystem.entryExists(prefix.appendingPathComponent(file.path)) else {
                throw DistributionError.installOwnershipMismatch(file.path)
            }
        }
        guard !DistributionFileSystem.entryExists(installManifestURL(prefix)) else {
            throw DistributionError.installOwnershipMismatch(
                DistributionLayout.installManifestFileName
            )
        }
        if journal.serviceBefore != .notInstalled {
            guard try captureManagedServiceState(
                prefix: prefix,
                cancellation: cancellation
            ) == .stopped else {
                throw DistributionError.lifecycleFailed(
                    "committed uninstall left the managed Hostwright service running"
                )
            }
        }
        if journal.dataPolicy == .remove,
           let statePath = journal.priorStatus?.stateDatabasePath,
           DistributionFileSystem.entryExists(URL(fileURLWithPath: statePath)) {
            throw DistributionError.lifecycleFailed(
                "committed uninstall state path reappeared before finalization"
            )
        }
        let recordedStatus = try loadOptional(
            DistributionInstallationStatus.self,
            from: statusURL(prefix)
        )
        var expectedStatus = journal.priorStatus
        if journal.packageReceiptCleanup == true,
           let status = expectedStatus,
           let origin = status.packageOrigin {
            expectedStatus = replacingPackageOrigin(
                in: status,
                with: origin.replacing(pendingReceiptCleanup: true)
            )
        }
        if let recordedStatus, recordedStatus != expectedStatus {
            throw DistributionError.lifecycleFailed(
                "committed uninstall status no longer matches its prior generation"
            )
        }
        if journal.packageReceiptCleanup == true {
            guard recordedStatus == expectedStatus, let recordedStatus else {
                throw DistributionError.lifecycleFailed(
                    "committed package uninstall lost its receipt cleanup marker"
                )
            }
            try DistributionPackageStagingCleanup.finalize(
                status: recordedStatus,
                receiptController: packageReceiptController,
                cancellation: cancellation
            )
        }
        try removeAllLifecycleContent(prefix: prefix)
    }

    private func performTransition(
        operation: DistributionLifecycleOperation,
        sourceRoot: URL,
        fromManifest: DistributionInstallManifest?,
        toManifest: DistributionInstallManifest,
        existingStatus: DistributionInstallationStatus?,
        serviceBefore: DistributionManagedServiceState,
        prefix: URL,
        stateDatabasePath: String?,
        targetStateSnapshot: StateUpgradeSnapshot?,
        authorizedRollbackOperationID: String?,
        packageOrigin: DistributionPackageOrigin?,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionInstallationStatus {
        if operation == .rollback {
            guard let stateDatabasePath else {
                guard targetStateSnapshot == nil else {
                    throw DistributionError.lifecycleFailed(
                        "rollback state snapshot is not bound to the installed state path"
                    )
                }
                return try performTransitionWithStateFenced(
                    operation: operation,
                    sourceRoot: sourceRoot,
                    fromManifest: fromManifest,
                    toManifest: toManifest,
                    existingStatus: existingStatus,
                    serviceBefore: serviceBefore,
                    prefix: prefix,
                    stateDatabasePath: nil,
                    targetStateSnapshot: nil,
                    authorizedRollbackOperationID: authorizedRollbackOperationID,
                    packageOrigin: packageOrigin,
                    cancellation: cancellation
                )
            }
            guard targetStateSnapshot?.databasePath == stateDatabasePath
                || targetStateSnapshot == nil else {
                throw DistributionError.lifecycleFailed(
                    "rollback state snapshot is not bound to the installed state path"
                )
            }
        }
        if geteuid() != 0, let stateDatabasePath, operation != .install {
            return try withStateLifecycleBoundary("hold the lifecycle state fence") {
                try StateUpgradeService(store: lifecycleStore(path: stateDatabasePath, prefix: prefix))
                    .withExclusiveLifecycleFence {
                        try performTransitionWithStateFenced(
                            operation: operation,
                            sourceRoot: sourceRoot,
                            fromManifest: fromManifest,
                            toManifest: toManifest,
                            existingStatus: existingStatus,
                            serviceBefore: serviceBefore,
                            prefix: prefix,
                            stateDatabasePath: stateDatabasePath,
                            targetStateSnapshot: targetStateSnapshot,
                            authorizedRollbackOperationID: authorizedRollbackOperationID,
                            packageOrigin: packageOrigin,
                            cancellation: cancellation
                        )
                    }
            }
        }
        return try performTransitionWithStateFenced(
            operation: operation,
            sourceRoot: sourceRoot,
            fromManifest: fromManifest,
            toManifest: toManifest,
            existingStatus: existingStatus,
            serviceBefore: serviceBefore,
            prefix: prefix,
            stateDatabasePath: stateDatabasePath,
            targetStateSnapshot: targetStateSnapshot,
            authorizedRollbackOperationID: authorizedRollbackOperationID,
            packageOrigin: packageOrigin,
            cancellation: cancellation
        )
    }

    private func performTransitionWithStateFenced(
        operation: DistributionLifecycleOperation,
        sourceRoot: URL,
        fromManifest: DistributionInstallManifest?,
        toManifest: DistributionInstallManifest,
        existingStatus: DistributionInstallationStatus?,
        serviceBefore: DistributionManagedServiceState,
        prefix: URL,
        stateDatabasePath: String?,
        targetStateSnapshot: StateUpgradeSnapshot?,
        authorizedRollbackOperationID: String?,
        packageOrigin: DistributionPackageOrigin?,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionInstallationStatus {
        if operation == .rollback, let stateDatabasePath {
            let currentStateExists = DistributionFileSystem.entryExists(
                URL(fileURLWithPath: stateDatabasePath)
            )
            guard currentStateExists == (targetStateSnapshot != nil) else {
                throw DistributionError.lifecycleFailed(
                    "rollback refused because current state presence no longer matches the verified rollback record"
                )
            }
        }
        let selectedPackageOrigin = packageOrigin
            ?? (operation == .repair ? existingStatus?.packageOrigin : nil)
        try selectedPackageOrigin?.validate()
        try verifyPayload(toManifest, root: sourceRoot, cancellation: cancellation)
        let operationID = UUID().uuidString.lowercased()
        var journal = DistributionLifecycleJournal(
            operationID: operationID,
            operation: operation,
            checkpoint: .intentRecorded,
            prefix: prefix.path,
            transactionRelativePath: transactionRelativePath(operationID),
            fromManifest: fromManifest,
            toManifest: toManifest,
            stateSnapshot: nil,
            serviceBefore: serviceBefore,
            dataPolicy: .preserve,
            startedAt: DistributionTimestamp.string(Date()),
            authorizedRollbackOperationID: authorizedRollbackOperationID,
            priorStatus: existingStatus
        )
        try journal.validate()
        try writeJournal(journal, prefix: prefix)
        try checkpointReached(.intentRecorded, cancellation: cancellation)
        let transaction = try createTransaction(prefix, operationID: operationID)
        let staged = transaction.appendingPathComponent("staged", isDirectory: true)
        try DistributionFileSystem.createExclusiveDirectory(staged)

        var ownerSession: DistributionOwnerStateSessionClient?
        defer {
            if let ownerSession { ownerSession.close(); Thread.current.threadDictionary.removeObject(forKey: rootOwnerSessionKey(prefix)) }
        }
        var transitionCommitted = false
        do {
            if geteuid() == 0, let stateDatabasePath, operation != .install,
               let existingStatus, let fromManifest {
                let receipt = try requiredRootOwnerReceipt(prefix: prefix, status: existingStatus)
                guard receipt.binding.databasePath == stateDatabasePath else {
                    throw DistributionError.lifecycleFailed("root transition differs from prepared owner state")
                }
                let helperManifest = operation == .rollback ? fromManifest : toManifest
                let helperSource = operation == .rollback ? prefix : sourceRoot
                let helper = transaction.appendingPathComponent("owner-helper/bin/hostwright-dist")
                try DistributionFileSystem.createExclusiveDirectory(transaction.appendingPathComponent("owner-helper"))
                try DistributionFileSystem.createExclusiveDirectory(helper.deletingLastPathComponent())
                guard let helperFile = helperManifest.files.first(where: { $0.path == "bin/hostwright-dist" }),
                      try fileMatches(helperFile, at: helperSource.appendingPathComponent(helperFile.path)) else {
                    throw DistributionError.lifecycleFailed("verified payload lacks exact owner-session helper")
                }
                try DistributionFileSystem.copyRegularFile(from: helperSource.appendingPathComponent(helperFile.path), to: helper, mode: 0o755)
                let descriptor = DistributionOwnerStateSessionDescriptor(schemaVersion: 1, operationID: operationID,
                    receipt: receipt, fromGeneration: existingStatus.generation, toGeneration: existingStatus.generation + 1,
                    fromManifest: fromManifest, toManifest: toManifest, helperPath: helper.path,
                    helperSHA256: helperFile.sha256, helperIdentity: try DarwinCurrentControlCodeIdentity.inspect(executablePath: helper.path))
                try descriptor.validate()
                try writeCanonicalReplacing(descriptor, to: transaction.appendingPathComponent("owner-session-v1.json"), mode: 0o600)
                journal = journal.replacing(checkpoint: journal.checkpoint, ownerStateDescriptorSHA256: try descriptor.digest)
                try writeJournal(journal, prefix: prefix)
                let client = try DistributionOwnerStateSessionClient(descriptor: descriptor, recovering: false, cancellation: cancellation)
                ownerSession = client
                Thread.current.threadDictionary[rootOwnerSessionKey(prefix)] = client
                try writeCanonicalReplacing(DistributionOwnerPreparationPending(operationID: descriptor.operationID,
                    installationID: descriptor.receipt.challenge.installationID, toGeneration: descriptor.toGeneration,
                    toManifestSHA256: DistributionHash.sha256(data: try DistributionJSON.encode(descriptor.toManifest)),
                    fromGeneration: descriptor.fromGeneration,
                    fromManifestSHA256: DistributionHash.sha256(data: try DistributionJSON.encode(descriptor.fromManifest))),
                    to: rootOwnerPreparationPendingURL(prefix), mode: 0o644)
                if let targetStateSnapshot { _ = try client.command("verify-restore", snapshot: targetStateSnapshot) }
            }
            for file in toManifest.files {
                try requireNotCancelled(cancellation, operation: "stage installed lifecycle payload")
                try DistributionFileSystem.copyRegularFile(
                    from: sourceRoot.appendingPathComponent(file.path),
                    to: staged.appendingPathComponent(file.path),
                    mode: file.mode
                )
            }
            try DistributionFileSystem.writeNewFile(
                try DistributionJSON.encode(toManifest),
                to: staged.appendingPathComponent(DistributionLayout.installManifestFileName),
                mode: 0o644
            )
            journal = journal.replacing(checkpoint: .payloadStaged)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.payloadStaged, cancellation: cancellation)

            if let fromManifest {
                let backup = transaction.appendingPathComponent("backup", isDirectory: true)
                try DistributionFileSystem.createExclusiveDirectory(backup)
                try backupInstalledPayload(
                    fromManifest,
                    prefix: prefix,
                    backup: backup,
                    cancellation: cancellation
                )
                journal = journal.replacing(checkpoint: .priorPayloadBackedUp)
                try writeJournal(journal, prefix: prefix)
                try checkpointReached(.priorPayloadBackedUp, cancellation: cancellation)
            }

            if let stateDatabasePath,
               operation != .install,
               DistributionFileSystem.entryExists(URL(fileURLWithPath: stateDatabasePath)) {
                let stateDirectory = transaction.appendingPathComponent("state", isDirectory: true)
                try DistributionFileSystem.createExclusiveDirectory(stateDirectory)
                let snapshot: StateUpgradeSnapshot
                if let ownerSession {
                    guard let retained = try ownerSession.command("snapshot").snapshot else {
                        throw DistributionError.lifecycleFailed("owner session returned no paired snapshot")
                    }
                    snapshot = retained
                } else {
                    snapshot = try StateUpgradeService(store: lifecycleStore(path: stateDatabasePath, prefix: prefix))
                        .createVerifiedSnapshot(at: stateDirectory.appendingPathComponent("state.sqlite").path)
                }
                let snapshotRecord = DistributionStateSnapshotRecord(
                    databasePath: snapshot.databasePath,
                    snapshotRelativePath: "\(transactionRelativePath(operationID))/state/state.sqlite",
                    databaseSHA256: snapshot.databaseSHA256,
                    databaseBytes: snapshot.databaseBytes,
                    stateSchemaVersion: snapshot.stateSchemaVersion,
                    ownerSnapshotPath: ownerSession == nil ? nil : snapshot.snapshotPath,
                    ownerUID: ownerSession?.descriptor.receipt.binding.ownerUID
                )
                journal = journal.replacing(checkpoint: .stateBackedUp, stateSnapshot: snapshotRecord)
                try writeJournal(journal, prefix: prefix)
                try checkpointReached(.stateBackedUp, cancellation: cancellation)
            }

            if operation != .install, serviceBefore != .notInstalled {
                try stopManagedService(
                    capturedState: serviceBefore,
                    prefix: prefix,
                    cancellation: cancellation
                )
                journal = journal.replacing(checkpoint: .serviceStopped)
                try writeJournal(journal, prefix: prefix)
                try checkpointReached(.serviceStopped, cancellation: cancellation)
            }

            journal = journal.replacing(checkpoint: .payloadPublishing)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.payloadPublishing, cancellation: cancellation)

            for path in payloadDirectories(for: toManifest.files).sorted() {
                let directory = prefix.appendingPathComponent(path, isDirectory: true)
                if !DistributionFileSystem.entryExists(directory) {
                    try DistributionFileSystem.createExclusiveDirectory(directory, mode: 0o755)
                }
            }
            for file in toManifest.files {
                try requireNotCancelled(cancellation, operation: "publish installed lifecycle payload")
                try atomicMoveReplacing(
                    from: staged.appendingPathComponent(file.path),
                    to: prefix.appendingPathComponent(file.path)
                )
            }
            if let fromManifest {
                let targetPaths = Set(toManifest.files.map(\.path))
                for file in fromManifest.files where !targetPaths.contains(file.path) {
                    try requireNotCancelled(
                        cancellation,
                        operation: "remove superseded installed lifecycle payload"
                    )
                    let destination = prefix.appendingPathComponent(file.path)
                    guard try fileMatches(file, at: destination) else {
                        throw DistributionError.installOwnershipMismatch(file.path)
                    }
                    try removeExactOwnedFile(destination)
                }
                let targetDirectories = Set(toManifest.createdDirectories)
                try removeCreatedDirectoriesIfEmpty(
                    fromManifest.createdDirectories.filter {
                        !targetDirectories.contains($0)
                    },
                    prefix: prefix
                )
            }
            try atomicMoveReplacing(
                from: staged.appendingPathComponent(DistributionLayout.installManifestFileName),
                to: installManifestURL(prefix)
            )
            journal = journal.replacing(checkpoint: .payloadPublished)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.payloadPublished, cancellation: cancellation)

            journal = journal.replacing(checkpoint: .stateMigrating)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.stateMigrating, cancellation: cancellation)
            if let ownerSession {
                if operation == .rollback, let targetStateSnapshot {
                    _ = try ownerSession.command("restore", snapshot: targetStateSnapshot,
                        approved: verifiedNativeRollbackIdentities(root: prefix, manifest: toManifest),
                        current: fromManifest.map { verifiedNativeRollbackIdentities(root: transaction.appendingPathComponent("backup"), manifest: $0) } ?? [])
                } else { _ = try ownerSession.command("migrate") }
            } else if let stateDatabasePath, operation != .install {
                let stateService = try StateUpgradeService(store: lifecycleStore(path: stateDatabasePath, prefix: prefix))
                if operation == .rollback, let targetStateSnapshot {
                    _ = try stateService.restoreVerifiedSnapshotPreservingAudit(
                        targetStateSnapshot,
                        operationID: operationID,
                        keyStore: MacOSAuditSigningKeyStore(service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: stateDatabasePath)),
                        approvedInstalledCodeIdentities: verifiedNativeRollbackIdentities(root: prefix, manifest: toManifest),
                        expectedCurrentInstalledCodeIdentities: fromManifest.map { verifiedNativeRollbackIdentities(root: transaction.appendingPathComponent("backup"), manifest: $0) } ?? []
                    )
                } else if DistributionFileSystem.entryExists(URL(fileURLWithPath: stateDatabasePath)) {
                    _ = try stateService.migrateToLatest()
                }
            }
            journal = journal.replacing(checkpoint: .stateMigrated)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.stateMigrated, cancellation: cancellation)
            journal = journal.replacing(checkpoint: .verifying)
            try writeJournal(journal, prefix: prefix)
            try checkpointReached(.verifying, cancellation: cancellation)

            try verifyInstalledExecutableContracts(
                prefix: prefix,
                manifest: toManifest,
                cancellation: cancellation
            )
            if operation != .install, serviceBefore != .notInstalled, ownerSession == nil {
                try restoreManagedService(
                    to: serviceBefore,
                    prefix: prefix,
                    cancellation: cancellation
                )
                journal = journal.replacing(checkpoint: .serviceRestored)
                try writeJournal(journal, prefix: prefix)
                try checkpointReached(.serviceRestored, cancellation: cancellation)
            }
            let generation = (existingStatus?.generation ?? 0) + 1
            let rollbackOperationID: String?
            if operation == .upgrade, let fromManifest, let existingStatus {
                let rollback = DistributionRollbackRecord(
                    operationID: operationID,
                    priorGeneration: existingStatus.generation,
                    priorManifest: fromManifest,
                    installedManifest: toManifest,
                    backupRelativePath: "\(transactionRelativePath(operationID))/backup",
                    stateSnapshot: journal.stateSnapshot,
                    serviceBefore: journal.serviceBefore,
                    priorPackageOrigin: existingStatus.packageOrigin,
                    createdAt: DistributionTimestamp.string(Date())
                )
                try rollback.validate()
                try DistributionFileSystem.writeNewFile(
                    try DistributionJSON.encode(rollback),
                    to: transaction.appendingPathComponent(DistributionLayout.lifecycleRollbackFileName),
                    mode: 0o600
                )
                try synchronizeDirectory(transaction)
                rollbackOperationID = operationID
            } else {
                rollbackOperationID = nil
            }
            let status = DistributionInstallationStatus(
                installationID: existingStatus?.installationID ?? UUID().uuidString.lowercased(),
                generation: generation,
                prefix: prefix.path,
                installedManifest: toManifest,
                stateDatabasePath: stateDatabasePath,
                service: journal.serviceBefore,
                rollbackOperationID: rollbackOperationID,
                packageOrigin: selectedPackageOrigin,
                updatedAt: DistributionTimestamp.string(Date())
            )
            try status.validate()
            try writeCanonicalReplacing(status, to: statusURL(prefix), mode: 0o600)
            if interruptAfterStatusWrite {
                throw DistributionLifecycleInterruption.afterStatusWriteBeforeJournal
            }
            journal = journal.replacing(checkpoint: .statusPublished)
            try writeJournal(journal, prefix: prefix)
            if geteuid() == 0 { try publishPublicStateChallenge(status: status, prefix: prefix) }
            if let ownerSession {
                guard let refreshed = try ownerSession.command("commit").receipt else {
                    throw DistributionError.lifecycleFailed("owner commit returned no refreshed generation binding")
                }
                try writeCanonicalReplacing(refreshed, to: lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), mode: 0o600)
            }
            transitionCommitted = true
            try checkpointReached(.statusPublished, cancellation: cancellation)
            if let ownerSession {
                try ownerSession.finish()
                Thread.current.threadDictionary.removeObject(forKey: rootOwnerSessionKey(prefix))
                if serviceBefore != .notInstalled {
                    try restoreManagedService(to: serviceBefore, prefix: prefix, cancellation: cancellation)
                }
            }
            try finalizePublishedTransition(journal: journal, prefix: prefix)
            if ownerSession != nil, DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
                try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644)
            }
            return status
        } catch let interruption as DistributionLifecycleInterruption {
            throw interruption
        } catch {
            let primary = error
            if transitionCommitted {
                throw primary
            }
            do {
                try compensate(journal: journal, prefix: prefix)
                if let ownerSession {
                    try ownerSession.finish(recovery: true)
                    Thread.current.threadDictionary.removeObject(forKey: rootOwnerSessionKey(prefix))
                    if DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
                        try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644)
                    }
                }
            } catch {
                throw DistributionError.lifecycleFailed(
                    "lifecycle transition failed: \(String(describing: primary)); exact prior-generation recovery failed: \(String(describing: error))"
                )
            }
            throw primary
        }
    }

    private func compensate(
        journal: DistributionLifecycleJournal,
        prefix: URL
    ) throws {
        let transaction = transactionURL(prefix, operationID: journal.operationID)
        let recoveryCancellation = SecureSubprocessCancellation()
        if journal.serviceBefore != .notInstalled {
            let currentService = try captureManagedServiceState(
                prefix: prefix,
                cancellation: recoveryCancellation
            )
            if currentService == .running {
                try stopManagedService(
                    capturedState: currentService,
                    prefix: prefix,
                    cancellation: recoveryCancellation
                )
            }
        }
        var restoredPayloadFiles = 0
        if checkpointMayHaveChangedState(journal.checkpoint), let snapshot = journal.stateSnapshot {
            let stateSnapshot = StateUpgradeSnapshot(
                databasePath: snapshot.databasePath,
                snapshotPath: snapshot.ownerSnapshotPath ?? prefix.appendingPathComponent(snapshot.snapshotRelativePath).path,
                databaseSHA256: snapshot.databaseSHA256,
                databaseBytes: snapshot.databaseBytes,
                stateSchemaVersion: snapshot.stateSchemaVersion
            )
            if let ownerSession = activeRootOwnerSession(prefix) {
                guard snapshot.ownerUID == ownerSession.descriptor.receipt.binding.ownerUID else {
                    throw DistributionError.lifecycleFailed("compensation owner snapshot binding differs")
                }
                _ = try ownerSession.command("restore", snapshot: stateSnapshot,
                    approved: journal.fromManifest.map { verifiedNativeRollbackIdentities(root: transaction.appendingPathComponent("backup"), manifest: $0) } ?? [],
                    current: journal.toManifest.map { verifiedNativeRollbackIdentities(root: prefix, manifest: $0) } ?? [], recovery: true)
            } else {
            _ = try StateUpgradeService(store: lifecycleStore(path: snapshot.databasePath, prefix: prefix))
                .restoreVerifiedSnapshotPreservingAudit(
                    stateSnapshot,
                    operationID: journal.operationID,
                    keyStore: MacOSAuditSigningKeyStore(service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: snapshot.databasePath)),
                    approvedInstalledCodeIdentities: journal.fromManifest.map { verifiedNativeRollbackIdentities(root: transaction.appendingPathComponent("backup"), manifest: $0) } ?? [],
                    expectedCurrentInstalledCodeIdentities: journal.toManifest.map { verifiedNativeRollbackIdentities(root: prefix, manifest: $0) } ?? [],
                    allowAbsentCurrentStateForUninstallRecovery: journal.operation == .uninstall
                )
            }
        }
        if checkpointMayHavePublished(journal.checkpoint) {
            if let fromManifest = journal.fromManifest {
                let backup = transactionURL(prefix, operationID: journal.operationID)
                    .appendingPathComponent("backup", isDirectory: true)
                let inventory = try loadBackupInventory(
                    prefix: prefix,
                    operationID: journal.operationID,
                    manifest: fromManifest
                )
                try verifyBackupInventory(inventory, backup: backup)
                let priorPaths = Set(fromManifest.files.map(\.path))
                if let toManifest = journal.toManifest {
                    for file in toManifest.files where !priorPaths.contains(file.path) {
                        let destination = prefix.appendingPathComponent(file.path)
                        guard try !DistributionFileSystem.entryExists(destination)
                            || fileMatches(file, at: destination) else {
                            throw DistributionError.installOwnershipMismatch(file.path)
                        }
                        if DistributionFileSystem.entryExists(destination) {
                            try removeExactOwnedFile(destination)
                        }
                    }
                }
                for path in payloadDirectories(for: fromManifest.files).sorted() {
                    let directory = prefix.appendingPathComponent(path, isDirectory: true)
                    if !DistributionFileSystem.entryExists(directory) {
                        try DistributionFileSystem.createExclusiveDirectory(directory, mode: 0o755)
                    }
                }
                let backedUp = Dictionary(uniqueKeysWithValues: inventory.files.map { ($0.path, $0) })
                for file in fromManifest.files {
                    let destination = prefix.appendingPathComponent(file.path)
                    if let backupFile = backedUp[file.path] {
                        try copyBackupReplacing(
                            from: backup.appendingPathComponent(file.path),
                            to: destination,
                            mode: backupFile.mode,
                            operationID: journal.operationID
                        )
                        guard try backupFileMatches(backupFile, at: destination) else {
                            throw DistributionError.installOwnershipMismatch(file.path)
                        }
                        restoredPayloadFiles += 1
                        if interruptAfterCompensationRestoreCount == restoredPayloadFiles {
                            throw DistributionLifecycleInterruption.afterCompensationFilesRestored(
                                restoredPayloadFiles
                            )
                        }
                    } else if DistributionFileSystem.entryExists(destination) {
                        if let published = journal.toManifest?.files.first(where: { $0.path == file.path }) {
                            guard try fileMatches(published, at: destination) else {
                                throw DistributionError.installOwnershipMismatch(file.path)
                            }
                        }
                        try removeExactOwnedFile(destination)
                    }
                }
                try copyBackupReplacing(
                    from: backup.appendingPathComponent(DistributionLayout.installManifestFileName),
                    to: installManifestURL(prefix),
                    mode: 0o644,
                    operationID: journal.operationID
                )
                let restoredManifest = try DistributionJSON.decode(
                    DistributionInstallManifest.self,
                    from: installManifestURL(prefix)
                )
                guard restoredManifest == fromManifest else {
                    throw DistributionError.installOwnershipMismatch(
                        DistributionLayout.installManifestFileName
                    )
                }
                if let toManifest = journal.toManifest {
                    let restoredDirectories = Set(fromManifest.createdDirectories)
                    try removeCreatedDirectoriesIfEmpty(
                        toManifest.createdDirectories.filter {
                            !restoredDirectories.contains($0)
                        },
                        prefix: prefix
                    )
                }
            } else if let toManifest = journal.toManifest {
                for file in toManifest.files where DistributionFileSystem.entryExists(
                    prefix.appendingPathComponent(file.path)
                ) {
                    let url = prefix.appendingPathComponent(file.path)
                    guard try fileMatches(file, at: url) else {
                        throw DistributionError.installOwnershipMismatch(file.path)
                    }
                    try removeExactOwnedFile(url)
                }
                let manifest = installManifestURL(prefix)
                if DistributionFileSystem.entryExists(manifest) {
                    let installed = try DistributionJSON.decode(DistributionInstallManifest.self, from: manifest)
                    guard installed == toManifest else {
                        throw DistributionError.installOwnershipMismatch(
                            DistributionLayout.installManifestFileName
                        )
                    }
                    try removeExactOwnedFile(manifest)
                }
                try removeCreatedDirectoriesIfEmpty(toManifest.createdDirectories, prefix: prefix)
            }
        }
        if let priorStatus = journal.priorStatus {
            try writeCanonicalReplacing(priorStatus, to: statusURL(prefix), mode: 0o600)
            if let ownerSession = activeRootOwnerSession(prefix) {
                try publishPublicStateChallenge(status: priorStatus, prefix: prefix)
                guard let refreshed = try ownerSession.command("prepare-prior", recovery: true).receipt else {
                    throw DistributionError.lifecycleFailed("owner prior-generation binding refresh failed")
                }
                try writeCanonicalReplacing(refreshed, to: lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), mode: 0o600)
            }
        } else if DistributionFileSystem.entryExists(statusURL(prefix)) {
            try removeExactOwnedFile(statusURL(prefix))
        }
        if let ownerSession = activeRootOwnerSession(prefix) {
            try ownerSession.finish(recovery: true)
            Thread.current.threadDictionary.removeObject(forKey: rootOwnerSessionKey(prefix))
        }
        if journal.serviceBefore != .notInstalled {
            try restoreManagedService(
                to: journal.serviceBefore,
                prefix: prefix,
                cancellation: recoveryCancellation
            )
        }
        let completedJournal = journal.replacing(checkpoint: .compensationPublished)
        try writeJournal(completedJournal, prefix: prefix)
        try recordTerminalCleanupIfPaired(journal: completedJournal, prefix: prefix)
        try removeTransaction(prefix, operationID: journal.operationID)
        if interruptAfterCompensationTransactionRemoved {
            throw DistributionLifecycleInterruption.afterCompensationTransactionRemoved
        }
        try finishTerminalMetadataIfPresent(prefix: prefix)
        if DistributionFileSystem.entryExists(journalURL(prefix)) {
            try removeExactOwnedFile(journalURL(prefix))
        }
        if DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) {
            try removeExactOwnedFile(terminalCleanupURL(prefix), expectedMode: 0o600)
        }
        if journal.fromManifest == nil, journal.priorStatus == nil {
            try removeFoundationIfUninstalled(prefix)
        }
    }

    private func finalizeCompletedCompensation(
        journal: DistributionLifecycleJournal,
        prefix: URL
    ) throws {
        guard journal.checkpoint == .compensationPublished else {
            throw DistributionError.lifecycleFailed(
                "compensation finalization requires its durable completion marker"
            )
        }
        if let priorStatus = journal.priorStatus {
            guard try requiredStatus(prefix) == priorStatus else {
                throw DistributionError.lifecycleFailed(
                    "compensated lifecycle status no longer matches the prior generation"
                )
            }
            try verifyOwnedFiles(priorStatus.installedManifest, prefix: prefix)
            if journal.serviceBefore != .notInstalled {
                try restoreManagedService(
                    to: journal.serviceBefore,
                    prefix: prefix,
                    cancellation: SecureSubprocessCancellation()
                )
            }
        } else {
            guard !DistributionFileSystem.entryExists(statusURL(prefix)),
                  !DistributionFileSystem.entryExists(installManifestURL(prefix)) else {
                throw DistributionError.lifecycleFailed(
                    "interrupted initial install compensation is incomplete"
                )
            }
            if let toManifest = journal.toManifest {
                for file in toManifest.files {
                    guard !DistributionFileSystem.entryExists(
                        prefix.appendingPathComponent(file.path)
                    ) else {
                        throw DistributionError.lifecycleFailed(
                            "interrupted initial install payload remains after compensation"
                        )
                    }
                }
            }
            if journal.serviceBefore != .notInstalled {
                try restoreManagedService(
                    to: journal.serviceBefore,
                    prefix: prefix,
                    cancellation: SecureSubprocessCancellation()
                )
            }
        }
        try removeTransaction(prefix, operationID: journal.operationID)
        if DistributionFileSystem.entryExists(journalURL(prefix)) {
            try removeExactOwnedFile(journalURL(prefix))
        }
        if journal.fromManifest == nil, journal.priorStatus == nil {
            try removeFoundationIfUninstalled(prefix)
        }
    }

    private func captureManagedServiceState(
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> DistributionManagedServiceState {
        try requireNotCancelled(cancellation, operation: "inspect managed Hostwright service")
        let record = try managedServiceRecord(prefix: prefix)
        let printed = try launchctlPrint(
            cancellation: cancellation,
            allowUnavailableRootUserDomain: record == nil
        )
        let daemonPath = resolvedPath(prefix.appendingPathComponent("bin/hostwrightd").path)

        guard let record else {
            if let printed,
               let loadedProgram = launchdField("program", in: printed),
               resolvedPath(loadedProgram) == daemonPath {
                throw DistributionError.lifecycleFailed(
                    "the loaded Hostwright launchd service has no exact verified ownership record"
                )
            }
            try ensureNoRunningUnmanagedDaemon(prefix: prefix, cancellation: cancellation)
            return .notInstalled
        }

        guard let printed else {
            try ensureNoRunningUnmanagedDaemon(prefix: prefix, cancellation: cancellation)
            return .stopped
        }
        let pathMatches = launchdField("path", in: printed).map(resolvedPath)
            == resolvedPath(managedService.propertyListURL.path)
        let programMatches = launchdField("program", in: printed).map(resolvedPath)
            == resolvedPath(record.programPath)
        let stateMatches = launchdField("state", in: printed) == "running"
        let processMatches = try installedDaemonIsRunning(
            prefix: prefix,
            cancellation: cancellation
        )
        guard pathMatches, programMatches, stateMatches, processMatches else {
            throw DistributionError.lifecycleFailed(
                "the loaded Hostwright launchd service failed exact ownership validation " +
                "(record-path=\(pathMatches), program=\(programMatches), " +
                "running-state=\(stateMatches), process=\(processMatches))"
            )
        }
        return .running
    }

    private func stopManagedService(
        capturedState: DistributionManagedServiceState,
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard capturedState != .notInstalled else { return }
        let current = try captureManagedServiceState(prefix: prefix, cancellation: cancellation)
        guard current == capturedState else {
            throw DistributionError.lifecycleFailed(
                "managed Hostwright service state changed after lifecycle preflight"
            )
        }
        guard current == .running else { return }
        _ = try runner.run(
            executablePath: "/bin/launchctl",
            arguments: ["bootout", "\(managedService.domain)/\(managedService.label)"],
            label: "stop exact managed Hostwright service",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        try waitForManagedService(
            expected: .stopped,
            prefix: prefix,
            cancellation: cancellation
        )
    }

    private func restoreManagedService(
        to target: DistributionManagedServiceState,
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard target != .notInstalled else { return }
        let current = try captureManagedServiceState(prefix: prefix, cancellation: cancellation)
        switch (target, current) {
        case (.stopped, .stopped), (.running, .running):
            return
        case (.stopped, .running):
            try stopManagedService(
                capturedState: .running,
                prefix: prefix,
                cancellation: cancellation
            )
        case (.running, .stopped):
            _ = try runner.run(
                executablePath: "/bin/launchctl",
                arguments: ["bootstrap", managedService.domain, managedService.propertyListURL.path],
                label: "load exact managed Hostwright service",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            _ = try runner.run(
                executablePath: "/bin/launchctl",
                arguments: ["kickstart", "-k", "\(managedService.domain)/\(managedService.label)"],
                label: "start exact managed Hostwright service",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            try waitForManagedService(
                expected: .running,
                prefix: prefix,
                cancellation: cancellation
            )
        default:
            throw DistributionError.lifecycleFailed(
                "the exact managed Hostwright service record disappeared during lifecycle recovery"
            )
        }
    }

    private func waitForManagedService(
        expected: DistributionManagedServiceState,
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try requireNotCancelled(cancellation, operation: "wait for managed Hostwright service")
            if expected == .stopped {
                if try launchctlPrint(cancellation: cancellation) == nil,
                   !(try installedDaemonIsRunning(prefix: prefix, cancellation: cancellation)) {
                    return
                }
            } else if (try? captureManagedServiceState(
                prefix: prefix,
                cancellation: cancellation
            )) == expected {
                return
            }
            usleep(50_000)
        }
        throw DistributionError.lifecycleFailed(
            "managed Hostwright service did not reach \(expected.rawValue) state"
        )
    }

    private func managedServiceRecord(
        prefix: URL
    ) throws -> DistributionManagedLaunchdServiceRecord? {
        let url = managedService.propertyListURL
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o022 == 0,
              metadata.st_size > 0,
              metadata.st_size <= 1_048_576 else {
            throw DistributionError.lifecycleFailed(
                "the Hostwright launchd service record is not a safe current-user-owned regular file"
            )
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? handle.close()
            throw POSIXError(code)
        }
        guard openedMetadata.st_dev == metadata.st_dev,
              openedMetadata.st_ino == metadata.st_ino,
              openedMetadata.st_mode & S_IFMT == S_IFREG,
              openedMetadata.st_uid == geteuid(),
              openedMetadata.st_nlink == 1,
              openedMetadata.st_mode & 0o022 == 0,
              openedMetadata.st_size > 0,
              openedMetadata.st_size <= 1_048_576 else {
            try? handle.close()
            throw DistributionError.lifecycleFailed(
                "the Hostwright launchd service record changed while it was being opened"
            )
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        var currentMetadata = stat()
        guard lstat(url.path, &currentMetadata) == 0,
              currentMetadata.st_dev == openedMetadata.st_dev,
              currentMetadata.st_ino == openedMetadata.st_ino,
              data.count == Int(openedMetadata.st_size),
              let object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              object["Label"] as? String == managedService.label,
              let rawArguments = object["ProgramArguments"] as? [Any],
              rawArguments.count == 4,
              let arguments = rawArguments as? [String],
              arguments[1] == "--foreground",
              arguments[2] == "--config" else {
            throw DistributionError.lifecycleFailed(
                "the Hostwright launchd service record has an unsupported or ambiguous shape"
            )
        }
        let expectedDaemon = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            prefix.appendingPathComponent("bin/hostwrightd").path,
            role: "managed Hostwright service executable"
        )
        let normalizedProgram = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            arguments[0],
            role: "managed Hostwright service executable"
        )
        guard normalizedProgram == arguments[0], arguments[0] == expectedDaemon else {
            throw DistributionError.lifecycleFailed(
                "the Hostwright launchd service executable is not the exact managed daemon path"
            )
        }
        let normalizedConfig = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            arguments[3],
            role: "managed Hostwright service configuration"
        )
        guard normalizedConfig == arguments[3] else {
            throw DistributionError.lifecycleFailed(
                "the Hostwright launchd service configuration path is not normalized"
            )
        }
        return DistributionManagedLaunchdServiceRecord(
            programPath: arguments[0],
            configPath: arguments[3]
        )
    }

    private func launchctlPrint(
        cancellation: SecureSubprocessCancellation,
        allowUnavailableRootUserDomain: Bool = false
    ) throws -> String? {
        do {
            return try runner.run(
                executablePath: "/bin/launchctl",
                arguments: ["print", "\(managedService.domain)/\(managedService.label)"],
                label: "inspect exact managed Hostwright service",
                timeoutSeconds: 10,
                cancellation: cancellation
            ).standardOutput
        } catch let DistributionError.commandFailed(_, status) where status == 113 {
            return nil
        } catch let DistributionError.commandFailed(_, status)
            where status == 125
                && allowUnavailableRootUserDomain
                && managedService.domain == "gui/0" {
            return nil
        }
    }

    private func launchdField(_ key: String, in output: String) -> String? {
        let prefix = "\(key) = "
        return output.split(separator: "\n").compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
        }.first
    }

    private func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func ensureNoRunningUnmanagedDaemon(
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        guard try !installedDaemonIsRunning(prefix: prefix, cancellation: cancellation) else {
            throw DistributionError.lifecycleFailed(
                "an installed hostwrightd process is running without a Hostwright-managed service record; stop it before lifecycle mutation"
            )
        }
    }

    private func installedDaemonIsRunning(
        prefix: URL,
        cancellation: SecureSubprocessCancellation
    ) throws -> Bool {
        let daemonPath = resolvedPath(prefix.appendingPathComponent("bin/hostwrightd").path)
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard count >= 0 else {
            throw DistributionError.lifecycleFailed(
                "installed service process inventory could not be read safely"
            )
        }
        let running = pids.prefix(Int(count)).contains { pid in
            guard !cancellation.isCancelled, pid > 0, pid != getpid() else { return false }
            var path = [CChar](repeating: 0, count: 4_096)
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return false }
            let executable = String(
                decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            return resolvedPath(executable) == daemonPath
        }
        try requireNotCancelled(cancellation, operation: "inspect installed hostwrightd process ownership")
        return running
    }

    private func replacingServiceState(
        in status: DistributionInstallationStatus,
        with service: DistributionManagedServiceState
    ) -> DistributionInstallationStatus {
        DistributionInstallationStatus(
            installationID: status.installationID,
            generation: status.generation,
            prefix: status.prefix,
            installedManifest: status.installedManifest,
            stateDatabasePath: status.stateDatabasePath,
            service: service,
            rollbackOperationID: status.rollbackOperationID,
            packageOrigin: status.packageOrigin,
            updatedAt: status.updatedAt
        )
    }

    private func replacingPackageOrigin(
        in status: DistributionInstallationStatus,
        with packageOrigin: DistributionPackageOrigin
    ) -> DistributionInstallationStatus {
        DistributionInstallationStatus(
            installationID: status.installationID,
            generation: status.generation,
            prefix: status.prefix,
            installedManifest: status.installedManifest,
            stateDatabasePath: status.stateDatabasePath,
            service: status.service,
            rollbackOperationID: status.rollbackOperationID,
            packageOrigin: packageOrigin,
            updatedAt: status.updatedAt
        )
    }

    private func selectedStatePath(
        requested: String?,
        existingStatus: DistributionInstallationStatus?
    ) throws -> String? {
        if let requested {
            let normalized = try HostwrightLocalPathResolver.normalizedAbsolutePath(
                requested,
                role: "distribution lifecycle state database"
            )
            guard normalized == requested else {
                throw DistributionError.unsafePath("State database path must already be normalized.")
            }
            if let bound = existingStatus?.stateDatabasePath, bound != requested {
                throw DistributionError.lifecycleFailed(
                    "installed lifecycle state path cannot be changed during upgrade"
                )
            }
            return requested
        }
        return existingStatus?.stateDatabasePath
    }

    private func checkpointMayHavePublished(_ checkpoint: DistributionLifecycleCheckpoint) -> Bool {
        switch checkpoint {
        case .payloadPublishing, .payloadPublished, .stateMigrating, .stateMigrated,
             .serviceRestored, .verifying, .statusPublished, .compensationPublished:
            return true
        case .intentRecorded, .payloadStaged, .priorPayloadBackedUp, .stateBackedUp, .serviceStopped:
            return false
        }
    }

    private func checkpointMayHaveChangedState(_ checkpoint: DistributionLifecycleCheckpoint) -> Bool {
        switch checkpoint {
        case .stateMigrating, .stateMigrated, .serviceRestored, .verifying, .statusPublished,
             .compensationPublished:
            return true
        default:
            return false
        }
    }

    private func interruptIfRequested(_ checkpoint: DistributionLifecycleCheckpoint) throws {
        if interruptAfter == checkpoint {
            throw DistributionLifecycleInterruption.after(checkpoint)
        }
    }

    private func checkpointReached(
        _ checkpoint: DistributionLifecycleCheckpoint,
        cancellation: SecureSubprocessCancellation
    ) throws {
        if cancelAfter == checkpoint {
            cancellation.cancel()
        }
        try requireNotCancelled(
            cancellation,
            operation: "installed lifecycle checkpoint \(checkpoint.rawValue)"
        )
        try interruptIfRequested(checkpoint)
    }

    private func requiredStatus(_ prefix: URL) throws -> DistributionInstallationStatus {
        guard let status = try loadOptional(
            DistributionInstallationStatus.self,
            from: statusURL(prefix)
        ) else {
            throw DistributionError.lifecycleFailed("no managed Hostwright installation exists")
        }
        try status.validate()
        guard status.prefix == prefix.path else {
            throw DistributionError.lifecycleFailed("installation status belongs to another prefix")
        }
        let manifest = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: installManifestURL(prefix)
        )
        guard manifest == status.installedManifest else {
            throw DistributionError.lifecycleFailed("installed manifest does not match lifecycle status")
        }
        return status
    }

    private func terminalCleanupURL(_ prefix: URL) -> URL {
        lifecycleRoot(prefix).appendingPathComponent("terminal-cleanup-v1.json")
    }

    private func recordTerminalCleanupIfPaired(journal: DistributionLifecycleJournal, prefix: URL) throws {
        guard geteuid() == 0, let descriptorSHA256 = journal.ownerStateDescriptorSHA256 else { return }
        guard activeRootOwnerSession(prefix) == nil else {
            throw DistributionError.lifecycleFailed("terminal cleanup requires released owner session")
        }
        let status = try requiredStatus(prefix)
        try verifyOwnedFiles(status.installedManifest, prefix: prefix)
        guard try captureManagedServiceState(prefix: prefix, cancellation: SecureSubprocessCancellation()) == status.service else {
            throw DistributionError.lifecycleFailed("terminal cleanup requires completed service restoration")
        }
        let receiptURL = lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json")
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(receiptURL, ownerUID: 0, mode: 0o600)
        guard receipt.challenge.installationID == status.installationID, receipt.challenge.generation == status.generation,
              receipt.challenge.installedManifestSHA256 == DistributionHash.sha256(data: try DistributionJSON.encode(status.installedManifest)) else {
            throw DistributionError.lifecycleFailed("terminal cleanup owner receipt differs from completed generation")
        }
        let dispositions = DistributionTerminalCleanup.dispositions(journal)
        let proof = DistributionTerminalCleanup(schemaVersion: 1, journal: journal, completedStatus: status,
            adoptedOwnerReceiptSHA256: DistributionHash.sha256(data: try DistributionJSON.encode(receipt)),
            originalDescriptorSHA256: descriptorSHA256, deleteTransactionRelativePaths: dispositions.delete,
            retainTransactionRelativePaths: dispositions.retain)
        try proof.validate()
        try writeCanonicalReplacing(proof, to: terminalCleanupURL(prefix), mode: 0o600)
        try finishTerminalMetadataIfPresent(prefix: prefix, remove: false)
    }

    private func finishTerminalMetadataIfPresent(prefix: URL, remove: Bool = true) throws {
        guard DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) else { return }
        if DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
            let proof: DistributionTerminalCleanup = try readStateBindingJSON(terminalCleanupURL(prefix), ownerUID: 0, mode: 0o600)
            let pending: DistributionOwnerPreparationPending = try readStateBindingJSON(rootOwnerPreparationPendingURL(prefix), ownerUID: 0, mode: 0o644)
            guard pending.operationID == proof.journal.operationID,
                  pending.installationID == proof.completedStatus.installationID,
                  pending.fromGeneration == proof.journal.priorStatus?.generation,
                  pending.toGeneration == (proof.journal.priorStatus?.generation ?? 0) + 1 else {
                throw DistributionError.lifecycleFailed("terminal cleanup pending marker belongs to another operation")
            }
            if remove { try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644) }
        }
    }

    private func completeTerminalCleanup(prefix: URL) throws -> DistributionRecoveryResult {
        guard geteuid() == 0 else { throw DistributionError.lifecycleFailed("terminal cleanup proof requires root ownership") }
        let proof: DistributionTerminalCleanup = try readStateBindingJSON(terminalCleanupURL(prefix), ownerUID: 0, mode: 0o600)
        try proof.validate()
        guard proof.journal.prefix == prefix.path, try requiredStatus(prefix) == proof.completedStatus else {
            throw DistributionError.lifecycleFailed("terminal cleanup proof differs from installed status")
        }
        if let journal = try loadOptional(DistributionLifecycleJournal.self, from: journalURL(prefix)), journal != proof.journal {
            throw DistributionError.lifecycleFailed("terminal cleanup proof differs from live journal")
        }
        try verifyOwnedFiles(proof.completedStatus.installedManifest, prefix: prefix)
        let receipt: DistributionOwnerStateReceipt = try readStateBindingJSON(lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), ownerUID: 0, mode: 0o600)
        guard DistributionHash.sha256(data: try DistributionJSON.encode(receipt)) == proof.adoptedOwnerReceiptSHA256,
              try captureManagedServiceState(prefix: prefix, cancellation: SecureSubprocessCancellation()) == proof.completedStatus.service else {
            throw DistributionError.lifecycleFailed("terminal cleanup completed receipt or service changed")
        }
        try finishTerminalMetadataIfPresent(prefix: prefix, remove: false)
        for relative in proof.retainTransactionRelativePaths {
            guard try DistributionFileSystem.isDirectoryNonSymlink(prefix.appendingPathComponent(relative)),
                  try DistributionFileSystem.mode(of: prefix.appendingPathComponent(relative)) == 0o700 else {
                throw DistributionError.lifecycleFailed("terminal cleanup retained rollback transaction is missing")
            }
        }
        for relative in proof.deleteTransactionRelativePaths {
            try removeTransaction(prefix, operationID: URL(fileURLWithPath: relative).lastPathComponent)
        }
        try finishTerminalMetadataIfPresent(prefix: prefix)
        if DistributionFileSystem.entryExists(journalURL(prefix)) { try removeExactOwnedFile(journalURL(prefix)) }
        try removeExactOwnedFile(terminalCleanupURL(prefix), expectedMode: 0o600)
        return DistributionRecoveryResult(action: proof.journal.checkpoint == .compensationPublished ? .restoredPriorGeneration : .completedPublishedGeneration,
            operationID: proof.journal.operationID, status: proof.completedStatus)
    }

    private func finalizePublishedTransition(
        journal: DistributionLifecycleJournal,
        prefix: URL
    ) throws {
        try recordTerminalCleanupIfPaired(journal: journal, prefix: prefix)
        switch journal.operation {
        case .upgrade:
            if let oldRollback = journal.priorStatus?.rollbackOperationID,
               oldRollback != journal.operationID {
                try removeTransaction(prefix, operationID: oldRollback)
            }
        case .rollback:
            try removeTransaction(prefix, operationID: journal.operationID)
            if let authorized = journal.authorizedRollbackOperationID {
                try removeTransaction(prefix, operationID: authorized)
            }
        case .install, .repair:
            try removeTransaction(prefix, operationID: journal.operationID)
            if let oldRollback = journal.priorStatus?.rollbackOperationID {
                try removeTransaction(prefix, operationID: oldRollback)
            }
        case .uninstall:
            throw DistributionError.lifecycleFailed(
                "uninstall publication uses its dedicated finalization path"
            )
        }
        if interruptAfterPublishedTransactionCleanup {
            throw DistributionLifecycleInterruption.afterPublishedTransactionCleanup
        }
        try finishTerminalMetadataIfPresent(prefix: prefix)
        if DistributionFileSystem.entryExists(journalURL(prefix)) {
            try removeExactOwnedFile(journalURL(prefix))
        }
        if DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) {
            try removeExactOwnedFile(terminalCleanupURL(prefix), expectedMode: 0o600)
        }
    }

    private func verifyPayload(
        _ manifest: DistributionInstallManifest,
        root: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws {
        for file in manifest.files {
            try requireNotCancelled(cancellation, operation: "verify lifecycle payload source")
            guard try fileMatches(file, at: root.appendingPathComponent(file.path)) else {
                throw DistributionError.installOwnershipMismatch(file.path)
            }
        }
    }

    private func verifyOwnedFiles(
        _ manifest: DistributionInstallManifest,
        prefix: URL,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws {
        try verifyPayload(manifest, root: prefix, cancellation: cancellation)
        guard secureOwnedRegularFile(
            installManifestURL(prefix),
            expectedMode: 0o644
        ) else {
            throw DistributionError.installOwnershipMismatch(
                DistributionLayout.installManifestFileName
            )
        }
        let installed = try DistributionJSON.decode(
            DistributionInstallManifest.self,
            from: installManifestURL(prefix)
        )
        guard installed == manifest else {
            throw DistributionError.installOwnershipMismatch(DistributionLayout.installManifestFileName)
        }
    }

    private func verifyInstalledExecutableContracts(
        prefix: URL,
        manifest: DistributionInstallManifest,
        cancellation: SecureSubprocessCancellation
    ) throws {
        try verifyOwnedFiles(manifest, prefix: prefix, cancellation: cancellation)
        let installedPaths = Set(manifest.files.map(\.path))
        for executable in [
            "hostwright",
            "hostwright-control",
            "hostwright-containerization-helper",
            "hostwright-dist"
        ]
            where installedPaths.contains("bin/\(executable)") {
            let result = try runner.run(
                executablePath: prefix.appendingPathComponent("bin/\(executable)").path,
                arguments: ["--version"],
                label: "verify installed \(executable) version",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == manifest.packageVersion else {
                throw DistributionError.lifecycleFailed(
                    "installed \(executable) version output did not match its manifest"
                )
            }
        }
        for (executable, expectedVersion) in [
            ("hostwright-network-helper", "network-helper-protocol-v1"),
            ("hostwright-network-provider-worker", "network-provider-spi-v1")
        ] where installedPaths.contains("bin/\(executable)") {
            let result = try runner.run(
                executablePath: prefix.appendingPathComponent("bin/\(executable)").path,
                arguments: ["--version"],
                label: "verify installed \(executable) version",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == expectedVersion else {
                throw DistributionError.lifecycleFailed(
                    "installed \(executable) version output did not match its provider contract"
                )
            }
        }
        if installedPaths.contains("bin/hostwright-storage-helper") {
            let result = try runner.run(
                executablePath: prefix
                    .appendingPathComponent("bin/hostwright-storage-helper").path,
                arguments: ["--version"],
                label: "verify installed hostwright-storage-helper version",
                timeoutSeconds: 30,
                cancellation: cancellation
            )
            guard result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == LocalStorageProviderContract.providerVersion else {
                throw DistributionError.lifecycleFailed(
                    "installed hostwright-storage-helper version output did not match its provider contract"
                )
            }
        }
        let daemon = try runner.run(
            executablePath: prefix.appendingPathComponent("bin/hostwrightd").path,
            arguments: ["--help"],
            label: "verify installed hostwrightd safety contract",
            timeoutSeconds: 30,
            cancellation: cancellation
        )
        guard daemon.standardOutput.contains(
            "hostwrightd --foreground --config <hostwright.yaml>"
        ),
        daemon.standardOutput.contains(
            "hostwrightd --service --config <absolute-hostwright.yaml>"
        ),
        daemon.standardOutput.contains(
            "Mutations require exact provider capability, ownership, plan confirmation, and durable fencing."
        ) else {
            throw DistributionError.lifecycleFailed(
                "installed hostwrightd help did not preserve its safety boundary"
            )
        }
    }

    private func fileMatches(_ file: DistributionFileRecord, at url: URL) throws -> Bool {
        guard let inspection = try inspectOwnedRegularFile(
            url,
            expectedMode: file.mode,
            computeDigest: true
        ) else { return false }
        return inspection.sha256 == file.sha256
            && inspection.sizeBytes == file.sizeBytes
    }

    private func validateRepairableOwnedPaths(
        _ manifest: DistributionInstallManifest,
        prefix: URL
    ) throws {
        for file in manifest.files {
            let url = prefix.appendingPathComponent(file.path)
            if DistributionFileSystem.entryExists(url) {
                guard secureOwnedRegularFile(url, expectedMode: nil) else {
                    throw DistributionError.installOwnershipMismatch(file.path)
                }
            }
        }
    }

    private func backupInstalledPayload(
        _ manifest: DistributionInstallManifest,
        prefix: URL,
        backup: URL,
        cancellation: SecureSubprocessCancellation
    ) throws {
        var files: [DistributionPayloadBackupFile] = []
        for file in manifest.files {
            try requireNotCancelled(cancellation, operation: "back up installed payload")
            let source = prefix.appendingPathComponent(file.path)
            guard DistributionFileSystem.entryExists(source) else { continue }
            guard secureOwnedRegularFile(source, expectedMode: nil) else {
                throw DistributionError.installOwnershipMismatch(file.path)
            }
            let mode = try DistributionFileSystem.mode(of: source)
            let destination = backup.appendingPathComponent(file.path)
            try DistributionFileSystem.copyRegularFile(
                from: source,
                to: destination,
                mode: mode
            )
            try synchronizeFile(destination)
            try synchronizeDirectory(destination.deletingLastPathComponent())
            files.append(
                DistributionPayloadBackupFile(
                    path: file.path,
                    sha256: try DistributionHash.sha256(fileURL: destination),
                    sizeBytes: try DistributionFileSystem.size(of: destination),
                    mode: mode
                )
            )
        }
        let manifestBackup = backup.appendingPathComponent(DistributionLayout.installManifestFileName)
        try DistributionFileSystem.copyRegularFile(
            from: installManifestURL(prefix),
            to: manifestBackup,
            mode: 0o644
        )
        try synchronizeFile(manifestBackup)
        try synchronizeDirectory(manifestBackup.deletingLastPathComponent())
        let inventory = DistributionPayloadBackupInventory(files: files)
        try inventory.validate(manifest: manifest)
        try DistributionFileSystem.writeNewFile(
            try DistributionJSON.encode(inventory),
            to: transactionURLFromBackup(backup).appendingPathComponent(
                DistributionLayout.lifecycleBackupInventoryFileName
            ),
            mode: 0o600
        )
        try synchronizeDirectory(transactionURLFromBackup(backup))
    }

    private func transactionURLFromBackup(_ backup: URL) -> URL {
        backup.deletingLastPathComponent()
    }

    private func loadBackupInventory(
        prefix: URL,
        operationID: String,
        manifest: DistributionInstallManifest
    ) throws -> DistributionPayloadBackupInventory {
        let inventory = try DistributionJSON.decode(
            DistributionPayloadBackupInventory.self,
            from: transactionURL(prefix, operationID: operationID).appendingPathComponent(
                DistributionLayout.lifecycleBackupInventoryFileName
            )
        )
        try inventory.validate(manifest: manifest)
        return inventory
    }

    private func verifyBackupInventory(
        _ inventory: DistributionPayloadBackupInventory,
        backup: URL
    ) throws {
        for file in inventory.files {
            guard try backupFileMatches(file, at: backup.appendingPathComponent(file.path)) else {
                throw DistributionError.installOwnershipMismatch(file.path)
            }
        }
    }

    private func backupFileMatches(_ file: DistributionPayloadBackupFile, at url: URL) throws -> Bool {
        guard let inspection = try inspectOwnedRegularFile(
            url,
            expectedMode: file.mode,
            computeDigest: true
        ) else { return false }
        return inspection.sha256 == file.sha256
            && inspection.sizeBytes == file.sizeBytes
    }

    private func createTransaction(_ prefix: URL, operationID: String) throws -> URL {
        let transaction = transactionURL(prefix, operationID: operationID)
        try DistributionFileSystem.createExclusiveDirectory(transaction)
        return transaction
    }

    private func transactionRelativePath(_ operationID: String) -> String {
        "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleTransactionsDirectoryName)/\(operationID)"
    }

    private func transactionURL(_ prefix: URL, operationID: String) -> URL {
        prefix.appendingPathComponent(transactionRelativePath(operationID), isDirectory: true)
    }

    private func installManifestURL(_ prefix: URL) -> URL {
        prefix.appendingPathComponent(DistributionLayout.installManifestFileName)
    }

    private func lifecycleRoot(_ prefix: URL) -> URL {
        prefix.appendingPathComponent(DistributionLayout.lifecycleDirectoryName, isDirectory: true)
    }

    private func transactionsRoot(_ prefix: URL) -> URL {
        lifecycleRoot(prefix).appendingPathComponent(
            DistributionLayout.lifecycleTransactionsDirectoryName,
            isDirectory: true
        )
    }

    private func statusURL(_ prefix: URL) -> URL {
        lifecycleRoot(prefix).appendingPathComponent(DistributionLayout.lifecycleStatusFileName)
    }

    private func journalURL(_ prefix: URL) -> URL {
        lifecycleRoot(prefix).appendingPathComponent(DistributionLayout.lifecycleJournalFileName)
    }

    private func ensureFoundation(_ prefix: URL) throws {
        let root = lifecycleRoot(prefix)
        if DistributionFileSystem.entryExists(root) {
            try validateFoundation(prefix)
            return
        }
        try DistributionFileSystem.createExclusiveDirectory(root)
        do {
            try DistributionFileSystem.createExclusiveDirectory(transactionsRoot(prefix))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func validateFoundation(_ prefix: URL) throws {
        for directory in [lifecycleRoot(prefix), transactionsRoot(prefix)] {
            try validateManagedDirectory(
                directory,
                role: "lifecycle metadata directory",
                requiredMode: 0o700
            )
        }
    }

    private func refusePendingJournal(_ prefix: URL) throws {
        if DistributionFileSystem.entryExists(journalURL(prefix)) ||
            DistributionFileSystem.entryExists(terminalCleanupURL(prefix)) ||
            DistributionFileSystem.entryExists(canonicalStageURL(for: terminalCleanupURL(prefix))) {
            throw DistributionError.lifecycleFailed(
                "a lifecycle operation is pending; run hostwright-dist recover before another mutation"
            )
        }
    }

    private func refuseCanonicalWriteStage(_ prefix: URL) throws {
        if hasCanonicalWriteStage(prefix) {
            throw DistributionError.lifecycleFailed(
                "an incomplete canonical lifecycle write requires hostwright-dist recover before uninstall planning"
            )
        }
    }

    private func writeJournal(_ journal: DistributionLifecycleJournal, prefix: URL) throws {
        try journal.validate()
        try writeCanonicalReplacing(journal, to: journalURL(prefix), mode: 0o600)
    }

    private func writeCanonicalReplacing<T: Encodable>(_ value: T, to url: URL, mode: Int) throws {
        let temporary = canonicalStageURL(for: url)
        if DistributionFileSystem.entryExists(temporary) {
            try removeExactOwnedFile(temporary, expectedMode: mode)
        }
        try DistributionFileSystem.writeNewFile(try DistributionJSON.encode(value), to: temporary, mode: mode)
        var cleanupTemporary = true
        defer {
            if cleanupTemporary, DistributionFileSystem.entryExists(temporary) {
                try? removeExactOwnedFile(temporary, expectedMode: mode)
            }
        }
        try synchronizeDirectory(temporary.deletingLastPathComponent())
        if interruptAfterCanonicalStageWriteFor == url.lastPathComponent {
            cleanupTemporary = false
            throw DistributionLifecycleInterruption.afterCanonicalStageSynced(
                url.lastPathComponent
            )
        }
        if DistributionFileSystem.entryExists(url), try !DistributionFileSystem.isRegularNonSymlink(url) {
            throw DistributionError.unsafePath("Lifecycle JSON destination is not a regular file.")
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        cleanupTemporary = false
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func canonicalStageURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).next"
        )
    }

    private func cleanupCanonicalWriteStages(_ prefix: URL) throws {
        for destination in [statusURL(prefix), journalURL(prefix), stateBindingURL(prefix), terminalCleanupURL(prefix)] {
            let stage = canonicalStageURL(for: destination)
            if DistributionFileSystem.entryExists(stage) {
                try removeExactOwnedFile(stage, expectedMode: 0o600)
            }
        }
    }

    private func hasCanonicalWriteStage(_ prefix: URL) -> Bool {
        [statusURL(prefix), journalURL(prefix), stateBindingURL(prefix), terminalCleanupURL(prefix)]
            .map(canonicalStageURL(for:))
            .contains(where: DistributionFileSystem.entryExists)
    }

    private func loadOptional<T: Codable>(_ type: T.Type, from url: URL) throws -> T? {
        guard DistributionFileSystem.entryExists(url) else { return nil }
        return try DistributionJSON.decode(type, from: url)
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func atomicMoveReplacing(from source: URL, to destination: URL) throws {
        guard try DistributionFileSystem.isRegularNonSymlink(source) else {
            throw DistributionError.invalidArtifact("atomic lifecycle source is not a regular file")
        }
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func copyBackupReplacing(
        from source: URL,
        to destination: URL,
        mode: Int,
        operationID: String
    ) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).recovery-\(operationID).next"
        )
        if DistributionFileSystem.entryExists(temporary) {
            try removeExactOwnedFile(temporary)
        }
        var published = false
        defer {
            if !published, DistributionFileSystem.entryExists(temporary) {
                try? removeExactOwnedFile(temporary)
            }
        }
        try DistributionFileSystem.copyRegularFile(from: source, to: temporary, mode: mode)
        try synchronizeFile(temporary)
        try atomicMoveReplacing(from: temporary, to: destination)
        published = true
    }

    private func removeExactOwnedFile(_ url: URL, expectedMode: Int? = nil) throws {
        guard let inspection = try inspectOwnedRegularFile(
            url,
            expectedMode: expectedMode,
            computeDigest: false
        ) else {
            throw DistributionError.installOwnershipMismatch(url.lastPathComponent)
        }
        var namedMetadata = stat()
        guard lstat(url.path, &namedMetadata) == 0,
              UInt64(namedMetadata.st_dev) == inspection.device,
              UInt64(namedMetadata.st_ino) == inspection.inode,
              Int(namedMetadata.st_mode & 0o777) == inspection.mode else {
            throw DistributionError.installOwnershipMismatch(url.lastPathComponent)
        }
        guard unlink(url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func secureOwnedRegularFile(_ url: URL, expectedMode: Int?) -> Bool {
        (try? inspectOwnedRegularFile(url, expectedMode: expectedMode, computeDigest: false)) != nil
    }

    private func inspectOwnedRegularFile(
        _ url: URL,
        expectedMode: Int?,
        computeDigest: Bool
    ) throws -> DistributionOwnedFileInspection? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o7000 == 0,
              expectedMode == nil || Int(metadata.st_mode & 0o777) == expectedMode else {
            return nil
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: url.path,
                role: "managed distribution file"
            )
        } catch {
            return nil
        }

        var digest: String?
        if computeDigest {
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 { break }
                hasher.update(data: Data(buffer[0..<count]))
            }
            digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        var namedMetadata = stat()
        guard lstat(url.path, &namedMetadata) == 0,
              namedMetadata.st_mode & S_IFMT == S_IFREG,
              namedMetadata.st_dev == metadata.st_dev,
              namedMetadata.st_ino == metadata.st_ino else {
            return nil
        }
        return DistributionOwnedFileInspection(
            sha256: digest,
            sizeBytes: Int(metadata.st_size),
            mode: Int(metadata.st_mode & 0o777),
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private func removeTransaction(_ prefix: URL, operationID: String) throws {
        let transaction = transactionURL(prefix, operationID: operationID)
        guard DistributionFileSystem.entryExists(transaction) else { return }
        guard try DistributionFileSystem.isDirectoryNonSymlink(transaction),
              try DistributionFileSystem.mode(of: transaction) == 0o700 else {
            throw DistributionError.unsafePath("Lifecycle transaction is not an owned private directory.")
        }
        let allowedFiles = Set(
            [
                "\(DistributionLayout.lifecycleRollbackFileName)",
                "\(DistributionLayout.lifecycleBackupInventoryFileName)",
                "state/state.sqlite", "owner-session-v1.json", "owner-helper/bin/hostwright-dist"
            ] + ["staged", "backup"].flatMap { root in
                DistributionLayout.payloadModes.keys.map { "\(root)/\($0)" }
                    + ["\(root)/\(DistributionLayout.installManifestFileName)"]
            }
        )
        let entries = try FileManager.default.subpathsOfDirectory(atPath: transaction.path)
        let allowedDirectories = Set(
            ["staged", "backup", "state"] + allowedFiles.flatMap { path -> [String] in
                let components = path.split(separator: "/").map(String.init)
                var directories: [String] = []
                var current = ""
                for component in components.dropLast() {
                    current = current.isEmpty ? component : "\(current)/\(component)"
                    directories.append(current)
                }
                return directories
            }
        )
        for entry in entries {
            guard DistributionPathPolicy.isSafeRelativePath(entry) else {
                throw DistributionError.unsafePath("Lifecycle transaction contains an unsafe path.")
            }
            let url = transaction.appendingPathComponent(entry)
            if try DistributionFileSystem.isRegularNonSymlink(url) {
                guard allowedFiles.contains(entry) else {
                    throw DistributionError.unsafePath("Lifecycle transaction contains an unmanaged file.")
                }
            } else if try DistributionFileSystem.isDirectoryNonSymlink(url) {
                guard allowedDirectories.contains(entry) else {
                    throw DistributionError.unsafePath("Lifecycle transaction contains an unmanaged directory.")
                }
            } else {
                throw DistributionError.unsafePath("Lifecycle transaction contains an unsupported entry.")
            }
        }
        try FileManager.default.removeItem(at: transaction)
        try synchronizeDirectory(transactionsRoot(prefix))
    }

    private func removeFoundationIfUninstalled(_ prefix: URL) throws {
        guard !DistributionFileSystem.entryExists(statusURL(prefix)),
              !DistributionFileSystem.entryExists(journalURL(prefix)),
              try FileManager.default.contentsOfDirectory(atPath: transactionsRoot(prefix).path).isEmpty else {
            return
        }
        try cleanupCanonicalWriteStages(prefix)
        let lock = lifecycleRoot(prefix).appendingPathComponent(DistributionLayout.lifecycleLockFileName)
        if DistributionFileSystem.entryExists(lock) { try removeExactOwnedFile(lock) }
        try FileManager.default.removeItem(at: transactionsRoot(prefix))
        try FileManager.default.removeItem(at: lifecycleRoot(prefix))
        try synchronizeDirectory(prefix)
    }

    private func removeAllLifecycleContent(prefix: URL) throws {
        try cleanupCanonicalWriteStages(prefix)
        let transactionEntries = try FileManager.default.contentsOfDirectory(atPath: transactionsRoot(prefix).path)
        for operationID in transactionEntries {
            guard DistributionLifecycleJournal.isCanonicalUUID(operationID) else {
                throw DistributionError.unsafePath("Lifecycle transactions contain an unmanaged entry.")
            }
            try removeTransaction(prefix, operationID: operationID)
        }
        if interruptAfterUninstallTransactionsRemoved {
            throw DistributionLifecycleInterruption.afterUninstallTransactionsRemoved
        }
        for file in [
            DistributionLayout.lifecycleStatusFileName,
            DistributionLayout.lifecycleJournalFileName,
            DistributionLayout.lifecycleLockFileName,
            "prepared-state-v1.json"
        ] {
            let url = lifecycleRoot(prefix).appendingPathComponent(file)
            if DistributionFileSystem.entryExists(url) { try removeExactOwnedFile(url) }
        }
        try FileManager.default.removeItem(at: transactionsRoot(prefix))
        try FileManager.default.removeItem(at: lifecycleRoot(prefix))
        try synchronizeDirectory(prefix)
    }

    private func validatePrefix(_ prefix: URL) throws {
        let path = prefix.path
        guard path.hasPrefix("/"),
              prefix.standardizedFileURL.resolvingSymlinksInPath().path == path,
              !["/", "/System", "/Library", "/usr", "/bin", "/sbin"].contains(path),
              try DistributionFileSystem.isDirectoryNonSymlink(prefix) else {
            throw DistributionError.unsafePath(
                "Install prefix must be an existing normalized absolute non-symlink directory."
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard (owner == geteuid() || owner == 0), mode & 0o022 == 0 else {
            throw DistributionError.unsafePath(
                "Install prefix must be invoking-user/root owned and not group/other writable."
            )
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: path,
                role: "distribution install prefix"
            )
        } catch {
            throw DistributionError.unsafePath(
                "Install prefix must not grant access through an extended ACL."
            )
        }
        for directory in payloadDirectories() {
            let url = prefix.appendingPathComponent(directory, isDirectory: true)
            if DistributionFileSystem.entryExists(url) {
                try validateManagedDirectory(
                    url,
                    role: "install payload parent \(directory)",
                    requiredMode: nil
                )
            }
        }
    }

    private func directoriesCreatedByInstalling(
        _ files: [DistributionFileRecord],
        prefix: URL
    ) -> [String] {
        payloadDirectories(for: files).filter {
            !DistributionFileSystem.entryExists(prefix.appendingPathComponent($0))
        }.sorted()
    }

    private func payloadDirectories(for files: [DistributionFileRecord]) -> [String] {
        payloadDirectories(forPaths: files.map(\.path))
    }

    private func payloadDirectories() -> [String] {
        payloadDirectories(forPaths: Array(DistributionLayout.payloadModes.keys))
    }

    private func payloadDirectories(forPaths paths: [String]) -> [String] {
        Array(Set(paths.flatMap { path -> [String] in
            let components = path.split(separator: "/").map(String.init)
            var directories: [String] = []
            var current = ""
            for component in components.dropLast() {
                current = current.isEmpty ? component : "\(current)/\(component)"
                directories.append(current)
            }
            return directories
        }))
    }

    @discardableResult
    private func removeCreatedDirectoriesIfEmpty(_ paths: [String], prefix: URL) throws -> [String] {
        var removed: [String] = []
        for path in paths.sorted(by: directoryDepthDescending) {
            let url = prefix.appendingPathComponent(path, isDirectory: true)
            guard DistributionFileSystem.entryExists(url),
                  try DistributionFileSystem.isDirectoryNonSymlink(url) else { continue }
            if try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                try FileManager.default.removeItem(at: url)
                removed.append(path)
            }
        }
        return removed.sorted()
    }

    private func directoryDepthDescending(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: "/").count
        let right = rhs.split(separator: "/").count
        return left == right ? lhs > rhs : left > right
    }

    private func validateManagedDirectory(
        _ url: URL,
        role: String,
        requiredMode: Int?
    ) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() || metadata.st_uid == 0,
              metadata.st_mode & 0o7000 == 0,
              metadata.st_mode & 0o022 == 0,
              requiredMode == nil || Int(metadata.st_mode & 0o777) == requiredMode else {
            throw DistributionError.unsafePath(
                "\(role) must be an invoking-user/root owned private non-symlink directory."
            )
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: url.path,
                role: role
            )
        } catch {
            throw DistributionError.unsafePath("\(role) must not grant access through an extended ACL.")
        }
    }

    private func requireNotCancelled(
        _ cancellation: SecureSubprocessCancellation,
        operation: String
    ) throws {
        guard !cancellation.isCancelled else {
            throw DistributionError.commandCancelled(operation)
        }
    }

    private func withStateLifecycleBoundary<T>(
        _ operation: String,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as DistributionError {
            throw error
        } catch let interruption as DistributionLifecycleInterruption {
            throw interruption
        } catch {
            throw DistributionError.lifecycleFailed(
                "\(operation) failed: \(String(describing: error))"
            )
        }
    }

    private func withJournalStateFence<T>(
        _ journal: DistributionLifecycleJournal,
        operation: String,
        _ body: () throws -> T
    ) throws -> T {
        let prefix = URL(fileURLWithPath: journal.prefix)
        if geteuid() == 0, let expectedDigest = journal.ownerStateDescriptorSHA256 {
            if activeRootOwnerSession(prefix) != nil { return try body() }
            let transaction = transactionURL(prefix, operationID: journal.operationID)
            let descriptor: DistributionOwnerStateSessionDescriptor = try readStateBindingJSON(
                transaction.appendingPathComponent("owner-session-v1.json"), ownerUID: 0, mode: 0o600)
            try descriptor.validate()
            guard try descriptor.digest == expectedDigest, descriptor.operationID == journal.operationID,
                  descriptor.receipt.challenge.prefix == journal.prefix,
                  descriptor.receipt.challenge.installationID == journal.priorStatus?.installationID,
                  descriptor.fromGeneration == journal.priorStatus?.generation,
                  descriptor.fromManifest == journal.fromManifest, descriptor.toManifest == journal.toManifest,
                  descriptor.helperPath == transaction.appendingPathComponent("owner-helper/bin/hostwright-dist").path else {
                throw DistributionError.lifecycleFailed("root and owner recovery journals disagree")
            }
            let ownerJournal = URL(fileURLWithPath: descriptor.receipt.binding.localPathResolution!.layout.runtimeDirectory)
                .appendingPathComponent("distribution-state/\(descriptor.receipt.challenge.installationID)/\(descriptor.operationID)/owner-journal-v1.json")
            if !DistributionFileSystem.entryExists(ownerJournal), journal.checkpoint == .intentRecorded {
                return try body()
            }
            let client = try DistributionOwnerStateSessionClient(descriptor: descriptor, recovering: true,
                cancellation: SecureSubprocessCancellation())
            Thread.current.threadDictionary[rootOwnerSessionKey(prefix)] = client
            defer { client.close(); Thread.current.threadDictionary.removeObject(forKey: rootOwnerSessionKey(prefix)) }
            if let snapshot = journal.stateSnapshot {
                guard snapshot.ownerUID == descriptor.receipt.binding.ownerUID,
                      snapshot.ownerSnapshotPath == client.ready.snapshot?.snapshotPath,
                      snapshot.databaseSHA256 == client.ready.snapshot?.databaseSHA256,
                      snapshot.databaseBytes == client.ready.snapshot?.databaseBytes,
                      snapshot.stateSchemaVersion == client.ready.snapshot?.stateSchemaVersion else {
                    throw DistributionError.lifecycleFailed("paired recovery snapshot metadata differs")
                }
            }
            let result = try body()
            if DistributionFileSystem.entryExists(statusURL(prefix)),
               let current = try loadOptional(DistributionInstallationStatus.self, from: statusURL(prefix)),
               current.generation == descriptor.toGeneration {
                guard let receipt = try client.command("commit").receipt else {
                    throw DistributionError.lifecycleFailed("owner recovered commit proof missing")
                }
                try writeCanonicalReplacing(receipt, to: lifecycleRoot(prefix).appendingPathComponent("adopted-owner-state-v1.json"), mode: 0o600)
            }
            try client.finish()
            if DistributionFileSystem.entryExists(rootOwnerPreparationPendingURL(prefix)) {
                try removeExactOwnedFile(rootOwnerPreparationPendingURL(prefix), expectedMode: 0o644)
            }
            return result
        }
        if geteuid() == 0, journal.ownerStateDescriptorSHA256 == nil,
           !checkpointMayHaveChangedState(journal.checkpoint) { return try body() }
        guard let statePath = journal.stateSnapshot?.databasePath
            ?? journal.priorStatus?.stateDatabasePath else {
            return try body()
        }
        return try withStateLifecycleBoundary(operation) {
            try StateUpgradeService(store: lifecycleStore(path: statePath, prefix: URL(fileURLWithPath: journal.prefix)))
                .withExclusiveLifecycleFence(body)
        }
    }
}

private final class DistributionLifecycleFileLock {
    private var descriptor: Int32

    init(prefix: URL, cancellation: SecureSubprocessCancellation) throws {
        guard !cancellation.isCancelled else {
            throw DistributionError.commandCancelled("distribution lifecycle lock preflight")
        }
        let path = prefix.appendingPathComponent(
            "\(DistributionLayout.lifecycleDirectoryName)/\(DistributionLayout.lifecycleLockFileName)"
        ).path
        descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR else {
            release()
            throw DistributionError.unsafePath("Lifecycle lock is not a private owned regular file.")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                let error = errno
                release()
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            guard !cancellation.isCancelled else {
                release()
                throw DistributionError.commandCancelled("wait for distribution lifecycle lock")
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                release()
                throw DistributionError.lifecycleFailed("another distribution lifecycle operation holds the prefix lock")
            }
            usleep(20_000)
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
