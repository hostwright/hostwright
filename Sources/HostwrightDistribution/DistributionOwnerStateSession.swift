import Darwin
import Foundation
import HostwrightCore
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightState

struct DistributionOwnerStateSessionDescriptor: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let operationID: String
    let receipt: DistributionOwnerStateReceipt
    let fromGeneration: Int
    let toGeneration: Int
    let fromManifest: DistributionInstallManifest
    let toManifest: DistributionInstallManifest
    let helperPath: String
    let helperSHA256: String
    let helperIdentity: CodeIdentity

    func validate() throws {
        try receipt.challenge.validate()
        try fromManifest.validate()
        try toManifest.validate()
        guard schemaVersion == 1, let id = UUID(uuidString: operationID), id.uuidString.lowercased() == operationID,
              fromGeneration == receipt.challenge.generation, toGeneration == fromGeneration + 1,
              [fromManifest, toManifest].contains(where: { $0.files.first(where: { $0.path == "bin/hostwright-dist" })?.sha256 == helperSHA256 }),
              DistributionHash.sha256(data: try DistributionJSON.encode(fromManifest)) == receipt.challenge.installedManifestSHA256,
              helperIdentity.validationMode == .installedRequirement, helperIdentity.signingIdentifier == "hostwright-dist",
              try HostwrightLocalPathResolver.normalizedAbsolutePath(helperPath, role: "owner session helper") == helperPath,
              receipt.binding.ownerUID != 0, receipt.binding.preparedGeneration == fromGeneration else {
            throw DistributionError.lifecycleFailed("owner session descriptor is inconsistent")
        }
    }
    var digest: String { get throws { DistributionHash.sha256(data: try DistributionJSON.encode(self)) } }
}

struct DistributionOwnerStateOperationJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let descriptorSHA256: String
    let descriptor: DistributionOwnerStateSessionDescriptor
    let snapshot: StateUpgradeSnapshot?
    let checkpoint: String
}

struct DistributionOwnerStateSessionCommand: Codable, Sendable {
    let sequence: Int
    let action: String
    var snapshot: StateUpgradeSnapshot? = nil
    var approvedIdentities: [CodeIdentity] = []
    var currentIdentities: [CodeIdentity] = []
}

struct DistributionOwnerStateSessionReply: Codable, Sendable {
    let sequence: Int
    let success: Bool
    var snapshot: StateUpgradeSnapshot? = nil
    var revision: StateUpgradeRevision? = nil
    var head: AuditChainHeadAnchor? = nil
    var message: String? = nil
    var receipt: DistributionOwnerStateReceipt? = nil
}

struct DistributionOwnerPreparationPending: Codable {
    let operationID: String
    let installationID: String
    let toGeneration: Int
    let toManifestSHA256: String
    let fromGeneration: Int
    let fromManifestSHA256: String
}

struct DistributionOwnerStateSessionStart: Codable {
    let descriptor: DistributionOwnerStateSessionDescriptor
    let recovering: Bool
}

final class DistributionOwnerStateSessionClient: @unchecked Sendable {
    let descriptor: DistributionOwnerStateSessionDescriptor
    private var process: SecureDetachedProcess?
    private let input = Pipe()
    private let output = Pipe()
    private let cancellation: SecureSubprocessCancellation
    private var buffered = Data()
    private var sequence = 0
    private var closed = false
    private(set) var ready = DistributionOwnerStateSessionReply(sequence: 0, success: false)

    init(descriptor: DistributionOwnerStateSessionDescriptor, recovering: Bool,
         cancellation: SecureSubprocessCancellation) throws {
        self.descriptor = descriptor
        self.cancellation = cancellation
        do {
            guard getuid() == 0, geteuid() == 0 else { throw DistributionError.lifecycleFailed("owner session launcher requires root") }
            try descriptor.validate()
            guard try DistributionHash.sha256(fileURL: URL(fileURLWithPath: descriptor.helperPath)) == descriptor.helperSHA256,
                  try DarwinCurrentControlCodeIdentity.inspect(executablePath: descriptor.helperPath) == descriptor.helperIdentity else {
                throw DistributionError.lifecycleFailed("owner session helper no longer matches pinned native bytes")
            }
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
                  fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
                throw DistributionError.lifecycleFailed("owner session could not protect command pipes")
            }
            process = try SecureSubprocessRunner().launchDetached(
                SecureSubprocessRequest(
                    executablePath: "/bin/launchctl",
                    arguments: ["asuser", String(descriptor.receipt.binding.ownerUID), descriptor.helperPath, "owner-state-session-child"],
                    environment: SecureSubprocessEnvironment.minimal, workingDirectory: "/"
                ),
                standardInput: input.fileHandleForReading.fileDescriptor,
                standardOutput: output.fileHandleForWriting.fileDescriptor
            )
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try Self.writeFrame(DistributionOwnerStateSessionStart(descriptor: descriptor, recovering: recovering),
                descriptor: input.fileHandleForWriting.fileDescriptor, cancellation: cancellation)
            let reply = try Self.readFrame(DistributionOwnerStateSessionReply.self,
                descriptor: output.fileHandleForReading.fileDescriptor, buffered: &buffered, cancellation: cancellation)
            guard reply.sequence == 0, reply.success else {
                throw DistributionError.lifecycleFailed("owner fence acquisition refused: " + (reply.message ?? "no healthy reply"))
            }
            ready = reply
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func command(_ action: String, snapshot: StateUpgradeSnapshot? = nil,
                 approved: [CodeIdentity] = [], current: [CodeIdentity] = [], recovery: Bool = false) throws -> DistributionOwnerStateSessionReply {
        let cancellation = recovery ? SecureSubprocessCancellation() : self.cancellation
        guard !closed else { throw DistributionError.lifecycleFailed("owner session is closed") }
        sequence += 1
        guard sequence <= 100 else { throw DistributionError.lifecycleFailed("owner session command bound exceeded") }
        try Self.writeFrame(DistributionOwnerStateSessionCommand(sequence: sequence, action: action,
            snapshot: snapshot, approvedIdentities: approved, currentIdentities: current),
            descriptor: input.fileHandleForWriting.fileDescriptor, cancellation: cancellation)
        let reply = try Self.readFrame(DistributionOwnerStateSessionReply.self,
            descriptor: output.fileHandleForReading.fileDescriptor, buffered: &buffered, cancellation: cancellation)
        guard reply.sequence == sequence, reply.success else {
            throw DistributionError.lifecycleFailed("owner state command \(action) refused: " + (reply.message ?? "invalid reply"))
        }
        return reply
    }

    func finish(recovery: Bool = false) throws {
        guard !closed else { return }
        defer { close() }
        _ = try command("close", recovery: recovery)
        try? input.fileHandleForWriting.close()
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        guard let process else { throw DistributionError.lifecycleFailed("owner session process is missing") }
        while process.isRunning && DispatchTime.now().uptimeNanoseconds < deadline { usleep(10_000) }
        guard !process.isRunning, process.naturalExitStatus == 0 else {
            throw DistributionError.lifecycleFailed("owner session did not release its fence cleanly")
        }
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        process?.terminate(graceMilliseconds: 50)
        process = nil
    }

    static func writeFrame<T: Encodable>(_ value: T, descriptor: Int32,
                                         cancellation: SecureSubprocessCancellation) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value) + Data([10])
        guard data.count <= 1_048_576 else { throw DistributionError.lifecycleFailed("owner session frame exceeds limit") }
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        var offset = 0
        try data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline, cancellation: cancellation)
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                else { throw DistributionError.lifecycleFailed("owner session pipe write failed") }
            }
        }
    }

    static func readFrame<T: Decodable>(_ type: T.Type, descriptor: Int32, buffered: inout Data,
                                        cancellation: SecureSubprocessCancellation, timeoutMilliseconds: UInt64 = 30_000) throws -> T {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMilliseconds * 1_000_000
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                guard newline < 1_048_576 else { throw DistributionError.lifecycleFailed("owner session frame exceeds limit") }
                let frame = buffered[..<newline]
                buffered.removeSubrange(...newline)
                return try JSONDecoder().decode(type, from: frame)
            }
            guard buffered.count < 1_048_576 else { throw DistributionError.lifecycleFailed("owner session reply exceeds limit") }
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline, cancellation: cancellation)
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { buffered.append(contentsOf: bytes.prefix(count)) }
            else if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { throw DistributionError.lifecycleFailed("owner session pipe closed with retained recovery intent") }
        }
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: UInt64,
                             cancellation: SecureSubprocessCancellation) throws {
        while true {
            guard !cancellation.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline else {
                throw DistributionError.lifecycleFailed("owner session frame cancelled or timed out")
            }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let status = poll(&item, 1, 100)
            if status > 0 {
                guard item.revents & Int16(POLLERR | POLLNVAL) == 0 else {
                    throw DistributionError.lifecycleFailed("owner session pipe became invalid")
                }
                if item.revents & events != 0 { return }
                if item.revents & Int16(POLLHUP) != 0 { throw DistributionError.lifecycleFailed("owner session pipe reached EOF") }
            } else if status < 0 && errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}

public enum DistributionOwnerStateSessionService {
    public static func runRootChild() throws {
        guard getuid() == 0, geteuid() == 0 else { throw DistributionError.lifecycleFailed("owner service requires root launcher entry") }
        let cancellation = SecureSubprocessCancellation()
        var buffered = Data()
        _ = fcntl(STDIN_FILENO, F_SETFL, O_NONBLOCK)
        _ = fcntl(STDOUT_FILENO, F_SETFL, O_NONBLOCK)
        guard fcntl(STDOUT_FILENO, F_SETNOSIGPIPE, 1) == 0 else {
            throw DistributionError.lifecycleFailed("owner service could not protect reply pipe")
        }
        let start = try DistributionOwnerStateSessionClient.readFrame(DistributionOwnerStateSessionStart.self,
            descriptor: STDIN_FILENO, buffered: &buffered, cancellation: cancellation)
        do {
            guard getuid() == 0, geteuid() == 0 else { throw DistributionError.lifecycleFailed("owner service requires root launcher entry") }
            let descriptor = start.descriptor
            try descriptor.validate()
            let ownPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
            guard ownPath == descriptor.helperPath,
                  try DistributionHash.sha256(fileURL: URL(fileURLWithPath: ownPath)) == descriptor.helperSHA256,
                  try DarwinCurrentControlCodeIdentity.inspect(executablePath: ownPath) == descriptor.helperIdentity,
                  let account = getpwuid(descriptor.receipt.binding.ownerUID) else {
                throw DistributionError.lifecycleFailed("owner service native helper/account proof failed")
            }
            let uid = account.pointee.pw_uid
            let gid = account.pointee.pw_gid
            let home = String(cString: account.pointee.pw_dir)
            guard uid != 0, gid != 0, setgroups(0, nil) == 0, setgid(gid) == 0, setuid(uid) == 0,
                  getuid() == uid, geteuid() == uid, getgid() == gid, getegid() == gid else {
                throw DistributionError.lifecycleFailed("owner service failed irreversible privilege drop")
            }
            let groupCount = getgroups(0, nil)
            guard groupCount >= 0, groupCount <= 64 else { throw DistributionError.lifecycleFailed("owner service group check failed") }
            var groups = [gid_t](repeating: 0, count: Int(groupCount))
            guard groups.withUnsafeMutableBufferPointer({ getgroups(groupCount, $0.baseAddress) }) == groupCount,
                  groups.allSatisfy({ $0 == gid }) else { throw DistributionError.lifecycleFailed("owner service retained unexpected groups") }
            alarm(600)
            let configuration = try DistributionOwnerStateProbe.validatedOwnerConfiguration(descriptor.receipt.binding, homeDirectory: home)
            try ensurePrivateDirectory(URL(fileURLWithPath: configuration.localPathResolution!.layout.runtimeDirectory), owner: uid)
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(atPath: descriptor.receipt.receiptPath + ".lock", role: "owner registry lock")
            let registry = open(descriptor.receipt.receiptPath + ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard registry >= 0 else { throw DistributionError.lifecycleFailed("owner registry fence missing") }
            defer { _ = flock(registry, LOCK_UN); close(registry) }
            var registryMetadata = stat()
            guard fstat(registry, &registryMetadata) == 0, registryMetadata.st_mode & S_IFMT == S_IFREG,
                  registryMetadata.st_uid == uid, registryMetadata.st_mode & 0o777 == 0o600, registryMetadata.st_nlink == 1 else {
                throw DistributionError.lifecycleFailed("owner registry fence differs from prepared owner")
            }
            let registryDeadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
            while flock(registry, LOCK_EX | LOCK_NB) != 0 {
                guard (errno == EWOULDBLOCK || errno == EINTR), DispatchTime.now().uptimeNanoseconds < registryDeadline else {
                    throw DistributionError.lifecycleFailed("owner registry acquisition timed out")
                }
                usleep(50_000)
            }
            let receipt: DistributionOwnerStateReceipt = try readPrivateJSON(URL(fileURLWithPath: descriptor.receipt.receiptPath), owner: uid)
            let compatibleCommittedReceipt = start.recovering && receipt.binding.configuration == descriptor.receipt.binding.configuration &&
                receipt.binding.ownerUID == uid && receipt.challenge.installationID == descriptor.receipt.challenge.installationID &&
                receipt.challenge.generation == descriptor.toGeneration
            guard receipt == descriptor.receipt || compatibleCommittedReceipt else { throw DistributionError.lifecycleFailed("owner service receipt changed") }
            if !start.recovering {
                guard try DistributionInstalledLifecycle().preparedOwnerStateReceipt(
                    prefix: URL(fileURLWithPath: receipt.challenge.prefix), configuration: configuration) == receipt else {
                    throw DistributionError.lifecycleFailed("owner service public payload challenge changed")
                }
            }
            let root = URL(fileURLWithPath: configuration.localPathResolution!.layout.runtimeDirectory)
                .appendingPathComponent("distribution-state", isDirectory: true)
            let installation = root.appendingPathComponent(receipt.challenge.installationID, isDirectory: true)
            let operation = installation.appendingPathComponent(descriptor.operationID, isDirectory: true)
            for directory in [root, installation, operation] { try ensurePrivateDirectory(directory, owner: uid) }
            let journalPath = operation.appendingPathComponent("owner-journal-v1.json")
            let store = SQLiteStateStore(configuration: configuration)
            let service = StateUpgradeService(store: store)
            try service.withExclusiveLifecycleFence {
                let keys = try MacOSAuditSigningKeyStore(service: MacOSAuditSigningKeyStore.serviceName(stateDatabasePath: store.path))
                try verifyAudit(store: store, keys: keys)
                var journal = DistributionOwnerStateOperationJournal(schemaVersion: 1, descriptorSHA256: try descriptor.digest,
                    descriptor: descriptor, snapshot: nil, checkpoint: "ready")
                if FileManager.default.fileExists(atPath: journalPath.path) {
                    let previous: DistributionOwnerStateOperationJournal = try readPrivateJSON(journalPath, owner: uid)
                    guard start.recovering, previous.schemaVersion == 1,
                          previous.descriptor == descriptor, previous.descriptorSHA256 == (try descriptor.digest),
                          ["ready", "snapshotted", "migrated", "restored", "committed"].contains(previous.checkpoint) else {
                        throw DistributionError.lifecycleFailed("owner operation journal conflicts with root descriptor")
                    }
                    if let snapshot = previous.snapshot { try validateSnapshot(snapshot, configuration: configuration, installation: installation); try service.verify(snapshot) }
                    journal = previous
                } else if start.recovering {
                    throw DistributionError.lifecycleFailed("owner recovery journal is missing")
                } else { try writePrivateJSON(journal, to: journalPath, owner: uid) }
                try DistributionOwnerStateSessionClient.writeFrame(DistributionOwnerStateSessionReply(sequence: 0, success: true,
                    snapshot: journal.snapshot, revision: try service.verifiedRevision(), head: try keys.loadHead()),
                    descriptor: STDOUT_FILENO, cancellation: cancellation)
                var sequence = 0
                while sequence < 100 {
                    let command = try DistributionOwnerStateSessionClient.readFrame(DistributionOwnerStateSessionCommand.self,
                        descriptor: STDIN_FILENO, buffered: &buffered, cancellation: cancellation, timeoutMilliseconds: 180_000)
                    guard command.sequence == sequence + 1 else { throw DistributionError.lifecycleFailed("owner command sequence mismatch") }
                    sequence = command.sequence
                    var reply = DistributionOwnerStateSessionReply(sequence: sequence, success: true)
                    do {
                        switch command.action {
                        case "snapshot":
                            if journal.snapshot == nil {
                                let snapshot = try service.createVerifiedSnapshot(at: operation.appendingPathComponent("state.sqlite").path)
                                journal = DistributionOwnerStateOperationJournal(schemaVersion: 1, descriptorSHA256: try descriptor.digest,
                                    descriptor: descriptor, snapshot: snapshot, checkpoint: "snapshotted")
                                try writePrivateJSON(journal, to: journalPath, owner: uid)
                            }
                            reply.snapshot = journal.snapshot
                        case "verify", "verify-restore":
                            guard let snapshot = command.snapshot else { throw DistributionError.lifecycleFailed("verify snapshot missing") }
                            try validateSnapshot(snapshot, configuration: configuration, installation: installation)
                            try service.verify(snapshot)
                            if command.action == "verify-restore" {
                                guard snapshot.stateSchemaVersion != 18 else {
                                    throw DistributionError.lifecycleFailed("pre-audit bearer snapshots require an explicit compatible restore strategy")
                                }
                                if snapshot.stateSchemaVersion < 19, try store.schemaVersion() >= 19 {
                                    guard try keys.loadHead() == nil, try keys.configuredActiveKey() == nil,
                                          !(try store.controlIdentities.hasEstablishedIdentityAuthority()) else {
                                        throw DistributionError.lifecycleFailed("legacy rollback requires durable external audit/security ledger before payload mutation")
                                    }
                                }
                            }
                        case "revision": reply.revision = try service.verifiedRevision()
                        case "migrate":
                            guard journal.snapshot != nil else { throw DistributionError.lifecycleFailed("migration requires paired snapshot") }
                            _ = try service.migrateToLatest()
                            journal = DistributionOwnerStateOperationJournal(schemaVersion: 1, descriptorSHA256: try descriptor.digest,
                                descriptor: descriptor, snapshot: journal.snapshot, checkpoint: "migrated")
                            try writePrivateJSON(journal, to: journalPath, owner: uid)
                        case "restore":
                            guard let snapshot = command.snapshot else { throw DistributionError.lifecycleFailed("restore snapshot missing") }
                            try validateSnapshot(snapshot, configuration: configuration, installation: installation)
                            _ = try service.restoreVerifiedSnapshotPreservingAudit(snapshot, operationID: descriptor.operationID,
                                keyStore: keys, approvedInstalledCodeIdentities: command.approvedIdentities,
                                expectedCurrentInstalledCodeIdentities: command.currentIdentities)
                            journal = DistributionOwnerStateOperationJournal(schemaVersion: 1, descriptorSHA256: try descriptor.digest,
                                descriptor: descriptor, snapshot: journal.snapshot, checkpoint: "restored")
                            try writePrivateJSON(journal, to: journalPath, owner: uid)
                        case "commit", "prepare-prior":
                            try verifyAudit(store: store, keys: keys)
                            guard let revision = try service.verifiedRevision() else { throw DistributionError.lifecycleFailed("owner commit state missing") }
                            reply.receipt = try DistributionInstalledLifecycle().refreshOwnerSessionReceipt(
                                descriptor: descriptor, revision: revision, prior: command.action == "prepare-prior")
                            journal = DistributionOwnerStateOperationJournal(schemaVersion: 1, descriptorSHA256: try descriptor.digest,
                                descriptor: descriptor, snapshot: journal.snapshot, checkpoint: "committed")
                            try writePrivateJSON(journal, to: journalPath, owner: uid)
                        case "close":
                            try DistributionOwnerStateSessionClient.writeFrame(reply, descriptor: STDOUT_FILENO, cancellation: cancellation)
                            return
                        default: throw DistributionError.lifecycleFailed("owner command is outside bounded lifecycle protocol")
                        }
                        reply.head = try keys.loadHead()
                    } catch { reply = DistributionOwnerStateSessionReply(sequence: sequence, success: false, message: String(describing: error)) }
                    try DistributionOwnerStateSessionClient.writeFrame(reply, descriptor: STDOUT_FILENO, cancellation: cancellation)
                }
            }
        } catch {
            try? DistributionOwnerStateSessionClient.writeFrame(DistributionOwnerStateSessionReply(sequence: 0,
                success: false, message: String(describing: error)), descriptor: STDOUT_FILENO, cancellation: cancellation)
            throw error
        }
    }

    private static func verifyAudit(store: SQLiteStateStore, keys: MacOSAuditSigningKeyStore) throws {
        if try store.schemaVersion() < 18 {
            guard try keys.loadHead() == nil, try keys.configuredActiveKey() == nil,
                  !(try store.controlIdentities.hasEstablishedIdentityAuthority()) else {
                throw DistributionError.lifecycleFailed("legacy owner state cannot discard retained external audit or identity authority")
            }
            return
        }
        let before = try keys.loadHead()
        guard TamperEvidentAuditTrail(store: store, keyStore: keys).verify().health == .healthy,
              try keys.loadHead() == before else { throw DistributionError.lifecycleFailed("owner audit/Keychain authority is unhealthy") }
    }

    private static func validateSnapshot(_ snapshot: StateUpgradeSnapshot, configuration: StateStoreConfiguration,
                                         installation: URL) throws {
        try snapshot.validate()
        let url = URL(fileURLWithPath: snapshot.snapshotPath)
        guard snapshot.databasePath == configuration.databasePath,
              url.lastPathComponent == "state.sqlite", UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) != nil,
              url.deletingLastPathComponent().deletingLastPathComponent() == installation else {
            throw DistributionError.lifecycleFailed("owner snapshot is outside exact installation journal")
        }
    }

    private static func ensurePrivateDirectory(_ url: URL, owner: uid_t) throws {
        if mkdir(url.path, mode_t(0o700)) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard url.standardizedFileURL.resolvingSymlinksInPath().path == url.path,
              lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == owner, metadata.st_mode & 0o777 == 0o700 else { throw DistributionError.lifecycleFailed("owner journal directory is unsafe") }
        try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(atPath: url.path, role: "owner journal directory")
    }

    private static func readPrivateJSON<T: Decodable>(_ url: URL, owner: uid_t) throws -> T {
        try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(atPath: url.path, role: "owner state journal")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_uid == owner, before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o777 == 0o600, before.st_nlink == 1, before.st_size > 0, before.st_size <= 1_048_576 else {
            throw DistributionError.lifecycleFailed("owner state journal is not private bounded data")
        }
        let data = try handle.readToEnd() ?? Data()
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              after.st_dev == named.st_dev, after.st_ino == named.st_ino, named.st_mode == before.st_mode,
              named.st_uid == owner, named.st_nlink == 1, data.count == Int(before.st_size) else {
            throw DistributionError.lifecycleFailed("owner state journal changed while reading")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func writePrivateJSON<T: Encodable>(_ value: T, to url: URL, owner: uid_t) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".owner-journal-v1.json.next")
        if FileManager.default.fileExists(atPath: temporary.path) {
            let _: DistributionOwnerStateOperationJournal = try readPrivateJSON(temporary, owner: owner)
            guard unlink(temporary.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try DistributionJSON.encode(value)
        guard data.count <= 1_048_576 else { throw DistributionError.lifecycleFailed("owner journal exceeds limit") }
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
