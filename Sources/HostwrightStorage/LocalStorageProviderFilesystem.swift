import Darwin
import Foundation

struct LocalStorageRootMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let providerID: String
    let ownerUserID: UInt32
    let totalCapacityBytes: Int64

    init(ownerUserID: uid_t, totalCapacityBytes: Int64) {
        schemaVersion = Self.schemaVersion
        providerID = LocalStorageProviderContract.providerID
        self.ownerUserID = ownerUserID
        self.totalCapacityBytes = totalCapacityBytes
    }
}

struct LocalStorageAttachmentMetadata: Codable, Equatable, Sendable {
    let attachmentID: String
    let consumerID: String
    let generation: Int
    let fencingToken: String
    let readOnly: Bool
}

struct LocalStorageVolumeMetadata: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let ownershipMarker: String
    let providerID: String
    let volumeID: String
    let name: String
    let projectID: String
    let projectGeneration: Int
    let generation: Int
    let fencingToken: String
    let capacityBytes: Int64
    let retention: LocalStorageRetentionPolicy
    let attachments: [LocalStorageAttachmentMetadata]

    init(
        volumeID: String,
        name: String,
        projectID: String,
        projectGeneration: Int,
        generation: Int,
        fencingToken: String,
        capacityBytes: Int64,
        retention: LocalStorageRetentionPolicy,
        attachments: [LocalStorageAttachmentMetadata] = []
    ) {
        schemaVersion = Self.schemaVersion
        ownershipMarker = LocalStorageProviderContract.ownershipMarker
        providerID = LocalStorageProviderContract.providerID
        self.volumeID = volumeID
        self.name = name
        self.projectID = projectID
        self.projectGeneration = projectGeneration
        self.generation = generation
        self.fencingToken = fencingToken
        self.capacityBytes = capacityBytes
        self.retention = retention
        self.attachments = attachments.sorted {
            $0.attachmentID < $1.attachmentID
        }
    }
}

struct LocalStorageMutationIntent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let idempotencyKeySHA256: String
    let requestSHA256: String
    let canonicalRequest: Data
    let operation: StorageProviderOperation
    let requestID: String
    let context: StorageProviderMutationContext

    init(
        idempotencyKeySHA256: String,
        requestSHA256: String,
        canonicalRequest: Data,
        operation: StorageProviderOperation,
        requestID: UUID,
        context: StorageProviderMutationContext
    ) {
        schemaVersion = Self.schemaVersion
        self.idempotencyKeySHA256 = idempotencyKeySHA256
        self.requestSHA256 = requestSHA256
        self.canonicalRequest = canonicalRequest
        self.operation = operation
        self.requestID = requestID.uuidString.lowercased()
        self.context = context
    }
}

struct LocalStorageMutationReceipt: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let idempotencyKeySHA256: String
    let requestSHA256: String
    let operation: StorageProviderOperation
    let requestID: String
    let canonicalResult: Data

    init(
        idempotencyKeySHA256: String,
        requestSHA256: String,
        operation: StorageProviderOperation,
        requestID: UUID,
        canonicalResult: Data
    ) {
        schemaVersion = Self.schemaVersion
        self.idempotencyKeySHA256 = idempotencyKeySHA256
        self.requestSHA256 = requestSHA256
        self.operation = operation
        self.requestID = requestID.uuidString.lowercased()
        self.canonicalResult = canonicalResult
    }
}

struct LocalStorageVolumeScan: Sendable {
    let volumes: [(LocalStorageVolumeMetadata, LocalStorageVolumeObservation)]
    let unmanagedEntries: [String]
    let ambiguousVolumeIDs: [String]
}

final class LocalStorageFilesystemSession {
    static let ownershipFile = "ownership.json"
    static let dataDirectory = "data"

    let rootURL: URL
    let rootDevice: dev_t
    let totalCapacityBytes: Int64

    private let rootDescriptor: Int32
    private var volumesDescriptor: Int32 = -1
    private var recoveryDescriptor: Int32 = -1
    private var receiptsDescriptor: Int32 = -1
    private var lockDescriptor: Int32 = -1

    init(rootURL: URL, totalCapacityBytes: Int64) throws {
        guard totalCapacityBytes > 0,
              totalCapacityBytes <= StorageSemanticLimits.maximumCapacityBytes else {
            throw LocalStorageProviderError.invalidConfiguration
        }
        guard rootURL.isFileURL,
              Self.validAbsoluteNormalizedPath(rootURL.path) else {
            throw LocalStorageProviderError.unsafePath
        }
        self.rootURL = rootURL
        self.totalCapacityBytes = totalCapacityBytes

        rootDescriptor = try Self.openOrCreateAbsoluteDirectory(
            path: rootURL.path,
            requirePrivateLeaf: true
        )
        var rootMetadata = stat()
        guard fstat(rootDescriptor, &rootMetadata) == 0 else {
            Darwin.close(rootDescriptor)
            throw LocalStorageProviderError.ioFailure
        }
        rootDevice = rootMetadata.st_dev

        do {
            lockDescriptor = try Self.openOrCreatePrivateFile(
                parent: rootDescriptor,
                name: ".provider.lock",
                device: rootDevice
            )
            guard flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw LocalStorageProviderError.ioFailure
            }

            try Self.initializeRootMetadata(
                rootDescriptor: rootDescriptor,
                device: rootDevice,
                totalCapacityBytes: totalCapacityBytes
            )
            volumesDescriptor = try Self.openOrCreatePrivateDirectory(
                parent: rootDescriptor,
                name: "volumes",
                device: rootDevice
            )
            recoveryDescriptor = try Self.openOrCreatePrivateDirectory(
                parent: rootDescriptor,
                name: "recovery",
                device: rootDevice
            )
            receiptsDescriptor = try Self.openOrCreatePrivateDirectory(
                parent: rootDescriptor,
                name: "receipts",
                device: rootDevice
            )
        } catch {
            if receiptsDescriptor >= 0 {
                Darwin.close(receiptsDescriptor)
                receiptsDescriptor = -1
            }
            if recoveryDescriptor >= 0 {
                Darwin.close(recoveryDescriptor)
                recoveryDescriptor = -1
            }
            if volumesDescriptor >= 0 {
                Darwin.close(volumesDescriptor)
                volumesDescriptor = -1
            }
            if lockDescriptor >= 0 {
                _ = flock(lockDescriptor, LOCK_UN)
                Darwin.close(lockDescriptor)
                lockDescriptor = -1
            }
            Darwin.close(rootDescriptor)
            throw error
        }
    }

    deinit {
        if receiptsDescriptor >= 0 { Darwin.close(receiptsDescriptor) }
        if recoveryDescriptor >= 0 { Darwin.close(recoveryDescriptor) }
        if volumesDescriptor >= 0 { Darwin.close(volumesDescriptor) }
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            Darwin.close(lockDescriptor)
        }
        Darwin.close(rootDescriptor)
    }

    func scanVolumes() throws -> LocalStorageVolumeScan {
        var volumes: [(LocalStorageVolumeMetadata, LocalStorageVolumeObservation)] = []
        var unmanaged: [String] = []
        var ambiguous: [String] = []

        for name in try Self.directoryEntries(volumesDescriptor) {
            guard Self.validCanonicalUUID(name) else {
                unmanaged.append(name)
                continue
            }
            do {
                let metadata = try loadVolume(volumeID: name)
                let observation = try observe(metadata)
                volumes.append((metadata, observation))
            } catch {
                ambiguous.append(name)
            }
            guard volumes.count + unmanaged.count + ambiguous.count
                <= LocalStorageProviderContract.maximumVolumes else {
                throw LocalStorageProviderError.volumeLimitExceeded
            }
        }
        return LocalStorageVolumeScan(
            volumes: volumes.sorted { $0.0.volumeID < $1.0.volumeID },
            unmanagedEntries: unmanaged.sorted(),
            ambiguousVolumeIDs: ambiguous.sorted()
        )
    }

    func loadVolume(volumeID: String) throws -> LocalStorageVolumeMetadata {
        guard Self.validCanonicalUUID(volumeID) else {
            throw LocalStorageProviderError.invalidRequest
        }
        let directory = try openVolumeDirectory(volumeID: volumeID)
        defer { Darwin.close(directory) }
        do {
            let metadata: LocalStorageVolumeMetadata =
                try Self.readCanonicalJSON(
                    parent: directory,
                    name: Self.ownershipFile,
                    device: rootDevice
                )
            try validate(metadata, expectedVolumeID: volumeID)
            _ = try Self.openExistingPrivateDirectory(
                parent: directory,
                name: Self.dataDirectory,
                device: rootDevice
            ).closing()
            return metadata
        } catch {
            throw LocalStorageProviderError.ambiguousVolume
        }
    }

    func observe(_ metadata: LocalStorageVolumeMetadata) throws
        -> LocalStorageVolumeObservation
    {
        let directory = try openVolumeDirectory(volumeID: metadata.volumeID)
        defer { Darwin.close(directory) }
        let dataDescriptor = try Self.openExistingPrivateDirectory(
            parent: directory,
            name: Self.dataDirectory,
            device: rootDevice
        )
        defer { Darwin.close(dataDescriptor) }
        var dataMetadata = stat()
        guard fstat(dataDescriptor, &dataMetadata) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        let path = rootURL
            .appendingPathComponent("volumes", isDirectory: true)
            .appendingPathComponent(metadata.volumeID, isDirectory: true)
            .appendingPathComponent(Self.dataDirectory, isDirectory: true)
            .path
        return LocalStorageVolumeObservation(
            volumeID: metadata.volumeID,
            name: metadata.name,
            providerID: metadata.providerID,
            projectID: metadata.projectID,
            projectGeneration: metadata.projectGeneration,
            generation: metadata.generation,
            fencingToken: metadata.fencingToken,
            capacityBytes: metadata.capacityBytes,
            retention: metadata.retention,
            dataPath: path,
            dataDevice: UInt64(dataMetadata.st_dev),
            dataInode: UInt64(dataMetadata.st_ino),
            attachments: metadata.attachments.map {
                LocalStorageAttachmentObservation(
                    attachmentID: $0.attachmentID,
                    consumerID: $0.consumerID,
                    generation: $0.generation,
                    fencingToken: $0.fencingToken,
                    readOnly: $0.readOnly
                )
            }
        )
    }

    func createVolume(_ metadata: LocalStorageVolumeMetadata) throws
        -> LocalStorageMutationDisposition
    {
        try validate(metadata, expectedVolumeID: metadata.volumeID)
        if faccessat(
            volumesDescriptor,
            metadata.volumeID,
            F_OK,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            let existing: LocalStorageVolumeMetadata
            do {
                existing = try loadVolume(volumeID: metadata.volumeID)
            } catch {
                try repairPartialCreate(metadata)
                return .performed
            }
            guard existing == metadata else {
                throw LocalStorageProviderError.ownershipMismatch
            }
            return .alreadySatisfied
        }
        guard errno == ENOENT else {
            throw LocalStorageProviderError.ioFailure
        }
        guard mkdirat(
            volumesDescriptor,
            metadata.volumeID,
            S_IRWXU
        ) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        do {
            let directory = try openVolumeDirectory(
                volumeID: metadata.volumeID
            )
            defer { Darwin.close(directory) }
            _ = try Self.openOrCreatePrivateDirectory(
                parent: directory,
                name: Self.dataDirectory,
                device: rootDevice
            ).closing()
            try Self.writeCanonicalJSON(
                metadata,
                parent: directory,
                name: Self.ownershipFile,
                device: rootDevice
            )
            guard fsync(directory) == 0,
                  fsync(volumesDescriptor) == 0 else {
                throw LocalStorageProviderError.ioFailure
            }
            return .performed
        } catch {
            throw error
        }
    }

    func writeVolume(_ metadata: LocalStorageVolumeMetadata) throws {
        try validate(metadata, expectedVolumeID: metadata.volumeID)
        let directory = try openVolumeDirectory(volumeID: metadata.volumeID)
        defer { Darwin.close(directory) }
        let existing: LocalStorageVolumeMetadata = try Self.readCanonicalJSON(
            parent: directory,
            name: Self.ownershipFile,
            device: rootDevice
        )
        try validate(existing, expectedVolumeID: metadata.volumeID)
        try Self.writeCanonicalJSON(
            metadata,
            parent: directory,
            name: Self.ownershipFile,
            device: rootDevice
        )
    }

    func deleteVolume(_ expected: LocalStorageVolumeMetadata) throws {
        let current = try loadVolume(volumeID: expected.volumeID)
        guard current == expected else {
            throw LocalStorageProviderError.ownershipMismatch
        }
        guard current.attachments.isEmpty else {
            throw LocalStorageProviderError.volumeAttached
        }
        let directory = try openVolumeDirectory(volumeID: current.volumeID)
        defer { Darwin.close(directory) }
        let entries = Set(try Self.directoryEntries(directory))
        guard entries.isSubset(of: [
            Self.ownershipFile,
            Self.dataDirectory
        ]), entries.contains(Self.ownershipFile),
        entries.contains(Self.dataDirectory) else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        let data = try Self.openExistingPrivateDirectory(
            parent: directory,
            name: Self.dataDirectory,
            device: rootDevice
        )
        defer { Darwin.close(data) }
        try Self.removeContents(
            directory: data,
            device: rootDevice,
            owner: geteuid()
        )
        guard unlinkat(directory, Self.dataDirectory, AT_REMOVEDIR) == 0,
              unlinkat(directory, Self.ownershipFile, 0) == 0,
              fsync(directory) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        try verifyDirectoryIdentity(
            descriptor: directory,
            parent: volumesDescriptor,
            name: current.volumeID
        )
        guard unlinkat(
            volumesDescriptor,
            current.volumeID,
            AT_REMOVEDIR
        ) == 0,
        fsync(volumesDescriptor) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
    }

    func pendingRecoveryIDs() throws -> [String] {
        try Self.directoryEntries(recoveryDescriptor)
            .filter { Self.validJournalName($0) }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    func journalRecordCount() throws -> Int {
        let recovery = try Self.directoryEntries(recoveryDescriptor)
            .filter { Self.validJournalName($0) }
            .count
        let receipts = try Self.directoryEntries(receiptsDescriptor)
            .filter { Self.validJournalName($0) }
            .count
        return recovery + receipts
    }

    func loadIntent(keySHA256: String) throws -> LocalStorageMutationIntent? {
        try Self.readOptionalCanonicalJSON(
            LocalStorageMutationIntent.self,
            parent: recoveryDescriptor,
            name: Self.journalName(keySHA256),
            device: rootDevice
        )
    }

    func writeIntent(_ intent: LocalStorageMutationIntent) throws {
        guard try journalRecordCount()
            < LocalStorageProviderContract.maximumJournalRecords else {
            throw LocalStorageProviderError.journalLimitExceeded
        }
        try Self.writeCanonicalJSON(
            intent,
            parent: recoveryDescriptor,
            name: Self.journalName(intent.idempotencyKeySHA256),
            device: rootDevice
        )
    }

    func removeIntent(keySHA256: String) throws {
        try Self.removeOptionalFile(
            parent: recoveryDescriptor,
            name: Self.journalName(keySHA256),
            device: rootDevice
        )
    }

    func loadReceipt(keySHA256: String) throws -> LocalStorageMutationReceipt? {
        try Self.readOptionalCanonicalJSON(
            LocalStorageMutationReceipt.self,
            parent: receiptsDescriptor,
            name: Self.journalName(keySHA256),
            device: rootDevice
        )
    }

    func writeReceipt(_ receipt: LocalStorageMutationReceipt) throws {
        let receiptCount = try Self.directoryEntries(receiptsDescriptor)
            .filter { Self.validJournalName($0) }
            .count
        guard receiptCount <
            LocalStorageProviderContract.maximumJournalRecords else {
            throw LocalStorageProviderError.journalLimitExceeded
        }
        try Self.writeCanonicalJSON(
            receipt,
            parent: receiptsDescriptor,
            name: Self.journalName(receipt.idempotencyKeySHA256),
            device: rootDevice
        )
    }

    func filesystemAvailableBytes() throws -> Int64 {
        var statistics = statfs()
        guard fstatfs(rootDescriptor, &statistics) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        let (bytes, overflow) = Int64(statistics.f_bavail)
            .multipliedReportingOverflow(by: Int64(statistics.f_bsize))
        return overflow ? Int64.max : max(0, bytes)
    }

    private func repairPartialCreate(
        _ metadata: LocalStorageVolumeMetadata
    ) throws {
        let directory = try openVolumeDirectory(volumeID: metadata.volumeID)
        defer { Darwin.close(directory) }
        let entries = Set(try Self.directoryEntries(directory))
        guard entries.isSubset(of: [Self.dataDirectory]) else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        let data = try Self.openOrCreatePrivateDirectory(
            parent: directory,
            name: Self.dataDirectory,
            device: rootDevice
        )
        defer { Darwin.close(data) }
        guard try Self.directoryEntries(data).isEmpty else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        try Self.writeCanonicalJSON(
            metadata,
            parent: directory,
            name: Self.ownershipFile,
            device: rootDevice
        )
    }

    private func openVolumeDirectory(volumeID: String) throws -> Int32 {
        do {
            return try Self.openExistingPrivateDirectory(
                parent: volumesDescriptor,
                name: volumeID,
                device: rootDevice
            )
        } catch LocalStorageProviderError.ioFailure {
            throw LocalStorageProviderError.volumeNotFound
        }
    }

    private func validate(
        _ metadata: LocalStorageVolumeMetadata,
        expectedVolumeID: String
    ) throws {
        guard metadata.schemaVersion == LocalStorageVolumeMetadata.schemaVersion,
              metadata.ownershipMarker ==
                LocalStorageProviderContract.ownershipMarker,
              metadata.providerID == LocalStorageProviderContract.providerID,
              metadata.volumeID == expectedVolumeID,
              Self.validCanonicalUUID(metadata.volumeID),
              Self.validCanonicalUUID(metadata.projectID),
              Self.validCanonicalUUID(metadata.fencingToken),
              metadata.projectGeneration > 0,
              metadata.generation > 0,
              Self.validName(metadata.name),
              metadata.capacityBytes > 0,
              metadata.capacityBytes <= totalCapacityBytes,
              metadata.attachments.count <=
                LocalStorageProviderContract.maximumAttachmentsPerVolume,
              Set(metadata.attachments.map(\.attachmentID)).count ==
                metadata.attachments.count,
              metadata.attachments.allSatisfy({
                  Self.validCanonicalUUID($0.attachmentID) &&
                    Self.validName($0.consumerID) &&
                    $0.generation > 0
              }) else {
            throw LocalStorageProviderError.ownershipMismatch
        }
    }

    private func verifyDirectoryIdentity(
        descriptor: Int32,
        parent: Int32,
        name: String
    ) throws {
        var opened = stat()
        var named = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino else {
            throw LocalStorageProviderError.ambiguousVolume
        }
    }

    private static func initializeRootMetadata(
        rootDescriptor: Int32,
        device: dev_t,
        totalCapacityBytes: Int64
    ) throws {
        let expected = LocalStorageRootMetadata(
            ownerUserID: geteuid(),
            totalCapacityBytes: totalCapacityBytes
        )
        if let existing: LocalStorageRootMetadata =
            try readOptionalCanonicalJSON(
                LocalStorageRootMetadata.self,
                parent: rootDescriptor,
                name: "provider.json",
                device: device
            )
        {
            guard existing == expected else {
                throw LocalStorageProviderError.invalidConfiguration
            }
            return
        }
        let entries = Set(try directoryEntries(rootDescriptor))
        guard entries.isSubset(of: [".provider.lock"]) else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        try writeCanonicalJSON(
            expected,
            parent: rootDescriptor,
            name: "provider.json",
            device: device
        )
    }

    private static func openOrCreateAbsoluteDirectory(
        path: String,
        requirePrivateLeaf: Bool
    ) throws -> Int32 {
        guard validAbsoluteNormalizedPath(path) else {
            throw LocalStorageProviderError.unsafePath
        }
        var current = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard current >= 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        let components = path.split(separator: "/").map(String.init)
        if components.isEmpty {
            return current
        }
        do {
            for (index, component) in components.enumerated() {
                guard component != ".", component != "..", !component.isEmpty else {
                    throw LocalStorageProviderError.unsafePath
                }
                var next = openat(
                    current,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if next < 0, errno == ENOENT {
                    guard mkdirat(current, component, S_IRWXU) == 0 else {
                        throw LocalStorageProviderError.ioFailure
                    }
                    next = openat(
                        current,
                        component,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else {
                    throw LocalStorageProviderError.unsafePath
                }
                do {
                    try validateDirectory(
                        next,
                        privateLeaf: requirePrivateLeaf &&
                            index == components.count - 1,
                        device: nil
                    )
                } catch {
                    Darwin.close(next)
                    throw error
                }
                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private static func openOrCreatePrivateDirectory(
        parent: Int32,
        name: String,
        device: dev_t
    ) throws -> Int32 {
        var descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT {
            guard mkdirat(parent, name, S_IRWXU) == 0 else {
                throw LocalStorageProviderError.ioFailure
            }
            descriptor = openat(
                parent,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard fsync(parent) == 0 else {
                if descriptor >= 0 { Darwin.close(descriptor) }
                throw LocalStorageProviderError.ioFailure
            }
        }
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.unsafePath
        }
        do {
            try validateDirectory(
                descriptor,
                privateLeaf: true,
                device: device
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func openExistingPrivateDirectory(
        parent: Int32,
        name: String,
        device: dev_t
    ) throws -> Int32 {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        do {
            try validateDirectory(
                descriptor,
                privateLeaf: true,
                device: device
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        privateLeaf: Bool,
        device: dev_t?
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw LocalStorageProviderError.unsafePath
        }
        let owner = metadata.st_uid
        guard owner == geteuid() || (!privateLeaf && owner == 0) else {
            throw LocalStorageProviderError.unsafeOwnership
        }
        if privateLeaf {
            guard owner == geteuid(),
                  metadata.st_mode & 0o7777 == S_IRWXU else {
                throw LocalStorageProviderError.unsafePermissions
            }
        } else if metadata.st_mode & 0o022 != 0,
                  metadata.st_mode & S_ISVTX == 0 {
            throw LocalStorageProviderError.unsafePermissions
        }
        if let device, metadata.st_dev != device {
            throw LocalStorageProviderError.crossDeviceEntry
        }
    }

    private static func openOrCreatePrivateFile(
        parent: Int32,
        name: String,
        device: dev_t
    ) throws -> Int32 {
        let descriptor = openat(
            parent,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              metadata.st_dev == device else {
            Darwin.close(descriptor)
            throw LocalStorageProviderError.unsafePermissions
        }
        return descriptor
    }

    private static func writeCanonicalJSON<Value: Encodable>(
        _ value: Value,
        parent: Int32,
        name: String,
        device: dev_t
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard !data.isEmpty,
              data.count <= LocalStorageProviderContract.maximumMetadataBytes else {
            throw LocalStorageProviderError.ioFailure
        }
        try validateOptionalRegularFile(
            parent: parent,
            name: name,
            device: device
        )
        let temporaryName = ".\(name).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(
            parent,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        var removeTemporary = true
        defer {
            Darwin.close(descriptor)
            if removeTemporary {
                _ = unlinkat(parent, temporaryName, 0)
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0,
              renameat(parent, temporaryName, parent, name) == 0,
              fsync(parent) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        removeTemporary = false
    }

    private static func readCanonicalJSON<Value: Codable>(
        _ type: Value.Type = Value.self,
        parent: Int32,
        name: String,
        device: dev_t
    ) throws -> Value {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LocalStorageProviderError.ioFailure
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              metadata.st_dev == device,
              metadata.st_size > 0,
              metadata.st_size <=
                LocalStorageProviderContract.maximumMetadataBytes else {
            throw LocalStorageProviderError.unsafeOwnership
        }
        let data = try readAll(
            descriptor,
            byteCount: Int(metadata.st_size)
        )
        let decoded: Value
        do {
            decoded = try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LocalStorageProviderError.ambiguousVolume
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(decoded) == data else {
            throw LocalStorageProviderError.ambiguousVolume
        }
        return decoded
    }

    private static func readOptionalCanonicalJSON<Value: Codable>(
        _ type: Value.Type,
        parent: Int32,
        name: String,
        device: dev_t
    ) throws -> Value? {
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw LocalStorageProviderError.ioFailure
            }
            return nil
        }
        return try readCanonicalJSON(
            type,
            parent: parent,
            name: name,
            device: device
        )
    }

    private static func validateOptionalRegularFile(
        parent: Int32,
        name: String,
        device: dev_t
    ) throws {
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw LocalStorageProviderError.ioFailure
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == S_IRUSR | S_IWUSR,
              metadata.st_dev == device else {
            throw LocalStorageProviderError.unsafeOwnership
        }
    }

    private static func removeOptionalFile(
        parent: Int32,
        name: String,
        device: dev_t
    ) throws {
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else {
                throw LocalStorageProviderError.ioFailure
            }
            return
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_dev == device else {
            throw LocalStorageProviderError.unsafeOwnership
        }
        guard unlinkat(parent, name, 0) == 0,
              fsync(parent) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
    }

    private static func removeContents(
        directory: Int32,
        device: dev_t,
        owner: uid_t
    ) throws {
        for name in try directoryEntries(directory) {
            guard !Task<Never, Never>.isCancelled else {
                throw LocalStorageProviderError.cancelled
            }
            var metadata = stat()
            guard fstatat(
                directory,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0,
            metadata.st_dev == device,
            metadata.st_uid == owner else {
                throw LocalStorageProviderError.unsafeOwnership
            }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                let child = openat(
                    directory,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard child >= 0 else {
                    throw LocalStorageProviderError.unsafePath
                }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      opened.st_dev == metadata.st_dev,
                      opened.st_ino == metadata.st_ino else {
                    Darwin.close(child)
                    throw LocalStorageProviderError.unsafePath
                }
                do {
                    try removeContents(
                        directory: child,
                        device: device,
                        owner: owner
                    )
                } catch {
                    Darwin.close(child)
                    throw error
                }
                Darwin.close(child)
                var current = stat()
                guard fstatat(
                    directory,
                    name,
                    &current,
                    AT_SYMLINK_NOFOLLOW
                ) == 0,
                current.st_dev == opened.st_dev,
                current.st_ino == opened.st_ino,
                unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                    throw LocalStorageProviderError.unsafePath
                }
            } else {
                guard unlinkat(directory, name, 0) == 0 else {
                    throw LocalStorageProviderError.ioFailure
                }
            }
        }
        guard fsync(directory) == 0 else {
            throw LocalStorageProviderError.ioFailure
        }
    }

    private static func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw LocalStorageProviderError.ioFailure
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var entries: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            entries.append(name)
            guard entries.count <=
                LocalStorageProviderContract.maximumVolumes +
                LocalStorageProviderContract.maximumJournalRecords else {
                throw LocalStorageProviderError.volumeLimitExceeded
            }
        }
        return entries.sorted()
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw LocalStorageProviderError.ioFailure
                }
                offset += count
            }
        }
    }

    private static func readAll(
        _ descriptor: Int32,
        byteCount: Int
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(byteCount)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1_024, byteCount))
        while data.count < byteCount {
            let requested = min(buffer.count, byteCount - data.count)
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw LocalStorageProviderError.ioFailure
            }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    private static func journalName(_ digest: String) -> String {
        "\(digest).json"
    }

    private static func validJournalName(_ value: String) -> Bool {
        value.count == 64 + ".json".count &&
            value.hasSuffix(".json") &&
            value.dropLast(".json".count).allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0)
            }
    }

    static func validCanonicalUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value),
              value == value.lowercased() else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= StorageSemanticLimits.maximumNameBytes &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            value.range(
                of: "^[A-Za-z0-9](?:[A-Za-z0-9._:-]*[A-Za-z0-9])?$",
                options: .regularExpression
            ) != nil
    }

    static func validAbsoluteNormalizedPath(_ value: String) -> Bool {
        guard value.hasPrefix("/"),
              value != "/",
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }
        let components = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first?.isEmpty == true else {
            return false
        }
        return components.dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }
}

private extension Int32 {
    func closing() {
        Darwin.close(self)
    }
}
