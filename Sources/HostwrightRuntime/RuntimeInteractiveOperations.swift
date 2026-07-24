import Darwin
import Foundation

public enum RuntimeInteractiveOperationKind: String, Codable, CaseIterable, Equatable, Sendable {
    case exec
    case attach
    case copyIn = "copy-in"
    case copyOut = "copy-out"
    case export
    case inspect
    case stats
    case logsFollow = "logs-follow"
}

public enum RuntimeInteractiveError: Error, Equatable, Sendable {
    case capabilityUnavailable(operation: RuntimeInteractiveOperationKind, reason: String)
    case invalidResourceIdentifier
    case invalidProcessArguments
    case invalidContainerPath
    case invalidHostPath
    case unsafeHostPath
    case unsafeArchive(String)
    case invalidStreamFrame
    case streamFrameTooLarge
    case streamQueueClosed
    case streamQueueCancelled
    case inputBackpressureExceeded
    case processLaunchFailed(Int32)
    case processIOFailed(Int32)
    case processFailed(exitStatus: Int32, diagnostic: String)
    case processTimedOut
    case processCancelled
    case processTreeCleanupFailed
    case invalidStructuredOutput
}

public enum RuntimeInteractiveOperation: Equatable, Sendable {
    case exec(
        resourceIdentifier: String,
        arguments: [String],
        interactive: Bool,
        tty: Bool,
        workingDirectory: String?
    )
    case attach(resourceIdentifier: String, interactive: Bool, tty: Bool)
    case copyIn(
        resourceIdentifier: String,
        hostRoot: String,
        sourceRelativePath: String,
        containerDestinationPath: String
    )
    case copyOut(
        resourceIdentifier: String,
        containerSourcePath: String,
        hostRoot: String,
        destinationRelativePath: String
    )
    case export(
        resourceIdentifier: String,
        hostRoot: String,
        destinationRelativePath: String
    )
    case inspect(resourceIdentifier: String)
    case stats(resourceIdentifier: String)
    case logsFollow(resourceIdentifier: String, tail: Int)

    public var kind: RuntimeInteractiveOperationKind {
        switch self {
        case .exec: .exec
        case .attach: .attach
        case .copyIn: .copyIn
        case .copyOut: .copyOut
        case .export: .export
        case .inspect: .inspect
        case .stats: .stats
        case .logsFollow: .logsFollow
        }
    }

    public var resourceIdentifier: String {
        switch self {
        case .exec(let identifier, _, _, _, _),
             .attach(let identifier, _, _),
             .copyIn(let identifier, _, _, _),
             .copyOut(let identifier, _, _, _),
             .export(let identifier, _, _),
             .inspect(let identifier),
             .stats(let identifier),
             .logsFollow(let identifier, _):
            identifier
        }
    }
}

public struct RuntimeInteractiveCapabilityContract: Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let capabilitySHA256: String
    public let availableOperations: Set<RuntimeInteractiveOperationKind>
    public let unavailableReasons: [RuntimeInteractiveOperationKind: String]

    public init(snapshot: RuntimeCapabilitySnapshot) {
        providerID = snapshot.descriptor.providerID
        capabilitySHA256 = snapshot.canonicalSHA256

        if providerID == .appleContainerization {
            availableOperations =
                ContainerizationHelperInteractiveExecutor.supportedOperations(
                    in: snapshot
                )
            unavailableReasons = Dictionary(
                uniqueKeysWithValues:
                    RuntimeInteractiveOperationKind.allCases.compactMap {
                        operation in
                        ContainerizationHelperInteractiveExecutor
                            .unavailableReason(for: operation, in: snapshot)
                            .map { (operation, $0) }
                    }
            )
            return
        }

        guard providerID == .appleContainerCLI else {
            availableOperations = []
            unavailableReasons = Dictionary(
                uniqueKeysWithValues: RuntimeInteractiveOperationKind.allCases.map {
                    ($0, "The selected provider does not advertise the Phase 04 interactive protocol.")
                }
            )
            return
        }

        var statuses: [RuntimeProviderFeature: RuntimeProviderFeatureStatus] = [:]
        var duplicateFeatures = Set<RuntimeProviderFeature>()
        for status in snapshot.features {
            if statuses.updateValue(status, forKey: status.feature) != nil {
                duplicateFeatures.insert(status.feature)
            }
        }
        var available = Set<RuntimeInteractiveOperationKind>()
        var unavailable: [RuntimeInteractiveOperationKind: String] = [:]
        for operation in RuntimeInteractiveOperationKind.allCases {
            if operation == .attach {
                unavailable[operation] =
                    "Apple container 1.0/1.1 can attach only while starting a stopped container and cannot reattach a running container; lifecycle mutation must use the Hostwright saga."
                continue
            }
            if operation == .logsFollow {
                unavailable[operation] =
                    "Apple container 1.0/1.1 log follow exposes no stable cursor or timestamp from which Hostwright can resume after the CLI process restarts."
                continue
            }
            let requiredFeatures = Self.requiredFeatures(for: operation)
            let blockers = requiredFeatures.compactMap { feature -> String? in
                if duplicateFeatures.contains(feature) {
                    return "\(feature.rawValue) is duplicated"
                }
                guard let status = statuses[feature] else {
                    return "\(feature.rawValue) is missing"
                }
                guard status.state == .available, status.reason == .implemented else {
                    return "\(feature.rawValue) is \(status.state.rawValue)/\(status.reason.rawValue)"
                }
                return nil
            }
            if blockers.isEmpty {
                available.insert(operation)
            } else {
                unavailable[operation] = blockers.sorted().joined(separator: ", ")
            }
        }
        availableOperations = available
        unavailableReasons = unavailable
    }

    public func require(_ operation: RuntimeInteractiveOperationKind) throws {
        guard availableOperations.contains(operation) else {
            throw RuntimeInteractiveError.capabilityUnavailable(
                operation: operation,
                reason: unavailableReasons[operation] ?? "The provider did not advertise this operation."
            )
        }
    }

    private static func requiredFeatures(
        for operation: RuntimeInteractiveOperationKind
    ) -> [RuntimeProviderFeature] {
        switch operation {
        case .inspect, .stats:
            [.observation]
        case .exec, .copyIn, .copyOut, .export:
            [.processControl]
        case .attach:
            [.lifecycle, .processControl, .streaming]
        case .logsFollow:
            [.streaming, .cancellation]
        }
    }
}

public enum RuntimeStreamName: String, Codable, Equatable, Sendable {
    case standardOutput = "stdout"
    case standardError = "stderr"
    case control
}

public struct RuntimeStreamEnvelope: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumChunkBytes = 64 * 1_024
    public static let maximumFrameBytes = 8 * 1_024 * 1_024

    public let schemaVersion: Int
    public let sequence: UInt64
    public let stream: RuntimeStreamName
    public let payloadBase64: String
    public let endOfStream: Bool

    public init(
        sequence: UInt64,
        stream: RuntimeStreamName,
        payload: Data,
        endOfStream: Bool = false
    ) throws {
        guard payload.count <= Self.maximumChunkBytes else {
            throw RuntimeInteractiveError.streamFrameTooLarge
        }
        self.schemaVersion = Self.schemaVersion
        self.sequence = sequence
        self.stream = stream
        self.payloadBase64 = payload.base64EncodedString()
        self.endOfStream = endOfStream
    }

    public var payload: Data {
        Data(base64Encoded: payloadBase64) ?? Data()
    }

    public func ndjsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0a)
        guard data.count <= Self.maximumFrameBytes else {
            throw RuntimeInteractiveError.streamFrameTooLarge
        }
        return data
    }

    public static func decodeNDJSONLine(_ data: Data) throws -> RuntimeStreamEnvelope {
        guard data.count <= maximumFrameBytes else {
            throw RuntimeInteractiveError.streamFrameTooLarge
        }
        let line = data.last == 0x0a ? Data(data.dropLast()) : data
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              Set(object.keys) == Set([
                  "endOfStream",
                  "payloadBase64",
                  "schemaVersion",
                  "sequence",
                  "stream"
              ]) else {
            throw RuntimeInteractiveError.invalidStreamFrame
        }
        let decoded: RuntimeStreamEnvelope
        do {
            decoded = try JSONDecoder().decode(RuntimeStreamEnvelope.self, from: line)
        } catch {
            throw RuntimeInteractiveError.invalidStreamFrame
        }
        guard decoded.schemaVersion == schemaVersion,
              let payload = Data(base64Encoded: decoded.payloadBase64),
              payload.count <= maximumChunkBytes,
              payload.base64EncodedString() == decoded.payloadBase64 else {
            throw RuntimeInteractiveError.invalidStreamFrame
        }
        return decoded
    }

    public static func chunks(
        _ data: Data,
        stream: RuntimeStreamName,
        startingAt sequence: UInt64
    ) throws -> [RuntimeStreamEnvelope] {
        guard !data.isEmpty else { return [] }
        var result: [RuntimeStreamEnvelope] = []
        var offset = 0
        var nextSequence = sequence
        while offset < data.count {
            let upperBound = min(offset + maximumChunkBytes, data.count)
            result.append(
                try RuntimeStreamEnvelope(
                    sequence: nextSequence,
                    stream: stream,
                    payload: Data(data[offset..<upperBound])
                )
            )
            offset = upperBound
            nextSequence += 1
        }
        return result
    }

    public static func chunkCount(for data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return (data.count + maximumChunkBytes - 1) / maximumChunkBytes
    }
}

struct RuntimeInteractiveInspectOutput: Encodable {
    let schemaVersion = 1
    let providerID: String
    let capabilitySHA256: String
    let inventorySHA256: String
    let container: RuntimeInventoryContainer

    init(
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        inventorySHA256: String,
        container: RuntimeInventoryContainer
    ) {
        self.providerID = providerID.rawValue
        self.capabilitySHA256 = capabilitySHA256
        self.inventorySHA256 = inventorySHA256
        self.container = container
    }
}

struct RuntimeInteractiveStatsOutput: Encodable {
    let schemaVersion = 1
    let providerID: String
    let capabilitySHA256: String
    let resourceIdentifier: String
    let cpuUsageMicroseconds: UInt64
    let memoryUsageBytes: UInt64
    let memoryLimitBytes: UInt64
    let networkReceiveBytes: UInt64
    let networkTransmitBytes: UInt64
    let blockReadBytes: UInt64
    let blockWriteBytes: UInt64
    let processCount: Int

    init(
        providerID: RuntimeProviderID,
        capabilitySHA256: String,
        usage: RuntimeResourceUsageSnapshot
    ) {
        self.providerID = providerID.rawValue
        self.capabilitySHA256 = capabilitySHA256
        resourceIdentifier = usage.resourceIdentifier
        cpuUsageMicroseconds = usage.cpuUsageMicroseconds
        memoryUsageBytes = usage.memoryUsageBytes
        memoryLimitBytes = usage.memoryLimitBytes
        networkReceiveBytes = usage.networkReceiveBytes
        networkTransmitBytes = usage.networkTransmitBytes
        blockReadBytes = usage.blockReadBytes
        blockWriteBytes = usage.blockWriteBytes
        processCount = usage.processCount
    }
}

public final class RuntimeStreamBackpressureQueue: @unchecked Sendable {
    public static let maximumQueuedBytes = 1 * 1_024 * 1_024

    private let condition = NSCondition()
    private var frames: [(envelope: RuntimeStreamEnvelope, byteCount: Int)] = []
    private var queuedBytes = 0
    private var closed = false
    private var cancelled = false

    public init() {}

    public func enqueue(
        _ envelope: RuntimeStreamEnvelope,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        let frame = try envelope.ndjsonLine()
        guard frame.count <= Self.maximumQueuedBytes else {
            throw RuntimeInteractiveError.streamFrameTooLarge
        }

        condition.lock()
        defer { condition.unlock() }
        while !closed, queuedBytes + frame.count > Self.maximumQueuedBytes {
            if cancelled() {
                throw RuntimeInteractiveError.streamQueueCancelled
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        if cancelled() {
            throw RuntimeInteractiveError.streamQueueCancelled
        }
        guard !closed else {
            throw RuntimeInteractiveError.streamQueueClosed
        }
        frames.append((envelope, frame.count))
        queuedBytes += frame.count
        condition.broadcast()
    }

    public func enqueueWithoutWaiting(_ envelope: RuntimeStreamEnvelope) throws {
        let frameByteCount = try envelope.ndjsonLine().count
        guard frameByteCount <= Self.maximumQueuedBytes else {
            throw RuntimeInteractiveError.streamFrameTooLarge
        }
        try condition.withLock {
            guard !cancelled else {
                throw RuntimeInteractiveError.streamQueueCancelled
            }
            guard !closed else {
                throw RuntimeInteractiveError.streamQueueClosed
            }
            guard queuedBytes + frameByteCount <= Self.maximumQueuedBytes else {
                throw RuntimeInteractiveError.inputBackpressureExceeded
            }
            frames.append((envelope, frameByteCount))
            queuedBytes += frameByteCount
            condition.broadcast()
        }
    }

    public func dequeue(
        waitUntil deadline: Date? = nil
    ) throws -> RuntimeStreamEnvelope? {
        condition.lock()
        defer { condition.unlock() }
        while frames.isEmpty, !closed {
            if let deadline {
                if !condition.wait(until: deadline), frames.isEmpty {
                    return nil
                }
            } else {
                condition.wait()
            }
        }
        if cancelled {
            throw RuntimeInteractiveError.streamQueueCancelled
        }
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        queuedBytes -= frame.byteCount
        condition.broadcast()
        return frame.envelope
    }

    public func close() {
        condition.withLock {
            closed = true
            condition.broadcast()
        }
    }

    public func cancel() {
        condition.withLock {
            cancelled = true
            closed = true
            frames.removeAll()
            queuedBytes = 0
            condition.broadcast()
        }
    }

    public var bufferedByteCount: Int {
        condition.withLock { queuedBytes }
    }
}

public enum RuntimeContainerPathPolicy {
    public static func validate(_ path: String) throws {
        guard path.utf8.count <= 4_096,
              path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            throw RuntimeInteractiveError.invalidContainerPath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RuntimeInteractiveError.invalidContainerPath
        }
    }
}

private struct RuntimeHostPathIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
    }
}

public struct RuntimeInteractiveDescriptorBinding: Equatable, Sendable {
    public let sourceDescriptor: Int32
    public let targetDescriptor: Int32

    public init(sourceDescriptor: Int32, targetDescriptor: Int32) {
        self.sourceDescriptor = sourceDescriptor
        self.targetDescriptor = targetDescriptor
    }
}

public struct RuntimeConfinedHostPath: @unchecked Sendable {
    public enum Intent: Sendable {
        case readExisting
        case writeFile
        case writeDestination
    }

    public let root: String
    public let relativePath: String
    public let path: String
    public let intent: Intent

    private let rootDevice: UInt64
    private let rootInode: UInt64
    private let parentIdentities: [RuntimeHostPathIdentity]
    private let leafIdentity: RuntimeHostPathIdentity?
    private let pinned: RuntimePinnedHostPathStorage

    public init(root: String, relativePath: String, intent: Intent) throws {
        guard root.hasPrefix("/"),
              !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !root.contains("\0"),
              !relativePath.contains("\0") else {
            throw RuntimeInteractiveError.invalidHostPath
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeInteractiveError.invalidHostPath
        }

        let rootDescriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        defer { close(rootDescriptor) }
        var rootMetadata = stat()
        guard fstat(rootDescriptor, &rootMetadata) == 0,
              (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        var resolvedParentIdentities = [RuntimeHostPathIdentity(rootMetadata)]

        var directoryDescriptor = dup(rootDescriptor)
        guard directoryDescriptor >= 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        defer { close(directoryDescriptor) }

        for component in components.dropLast() {
            let next = openat(
                directoryDescriptor,
                String(component),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            var metadata = stat()
            guard fstat(next, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                close(next)
                throw RuntimeInteractiveError.unsafeHostPath
            }
            resolvedParentIdentities.append(RuntimeHostPathIdentity(metadata))
            close(directoryDescriptor)
            directoryDescriptor = next
        }

        let finalComponent = String(components.last!)
        var resolvedLeafIdentity: RuntimeHostPathIdentity?
        let finalDescriptor = openat(
            directoryDescriptor,
            finalComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer {
            if finalDescriptor >= 0 {
                close(finalDescriptor)
            }
        }
        var finalMetadata: stat?
        if finalDescriptor >= 0 {
            var metadata = stat()
            guard fstat(finalDescriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG ||
                    ((intent == .readExisting || intent == .writeDestination) &&
                        (metadata.st_mode & S_IFMT) == S_IFDIR) else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            resolvedLeafIdentity = RuntimeHostPathIdentity(metadata)
            finalMetadata = metadata
        } else if intent == .readExisting || errno != ENOENT {
            throw RuntimeInteractiveError.unsafeHostPath
        }

        pinned = try RuntimePinnedHostPathStorage(
            parentDescriptor: directoryDescriptor,
            finalName: finalComponent,
            intent: intent,
            existingDescriptor: finalDescriptor >= 0 ? finalDescriptor : nil,
            existingMetadata: finalMetadata
        )

        self.root = root
        self.relativePath = relativePath
        self.path = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
            .path
        self.intent = intent
        self.rootDevice = UInt64(rootMetadata.st_dev)
        self.rootInode = UInt64(rootMetadata.st_ino)
        self.parentIdentities = resolvedParentIdentities
        self.leafIdentity = resolvedLeafIdentity
    }

    public var invocationPath: String {
        pinned.invocationPath
    }

    public var workingDirectoryDescriptor: Int32? {
        pinned.workingDirectoryDescriptor
    }

    public var descriptorBindings: [RuntimeInteractiveDescriptorBinding] {
        pinned.descriptorBindings
    }

    public func validateArchiveOutput() throws {
        try pinned.validateArchiveOutput()
    }

    public func validateCopyOutput() throws {
        try pinned.validateCopyOutput()
    }

    public func finalizeOutput() throws {
        try pinned.finalizeOutput()
    }

    public func revalidate() throws {
        let current = try RuntimeConfinedHostPath(
            root: root,
            relativePath: relativePath,
            intent: intent
        )
        guard current.rootDevice == rootDevice,
              current.rootInode == rootInode,
              current.parentIdentities == parentIdentities,
              leafIdentity == nil || current.leafIdentity == leafIdentity else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
    }
}

private final class RuntimePinnedHostPathStorage: @unchecked Sendable {
    private enum Mode {
        case readFile
        case readDirectory
        case stagedFile
        case stagedDirectory
    }

    private struct PreparedStorage {
        let parentDescriptor: Int32
        let contentDescriptor: Int32
        let stagingName: String?
        let mode: Mode
    }

    private static let providerInputName = "provider-input"
    private static let providerOutputName = "provider-output.tar"

    private let lock = NSLock()
    private let parentDescriptor: Int32
    private let contentDescriptor: Int32
    private let finalName: String
    private let stagingName: String?
    private let mode: Mode
    private var finalized = false
    private var validatedOutputSnapshot: stat?

    init(
        parentDescriptor: Int32,
        finalName: String,
        intent: RuntimeConfinedHostPath.Intent,
        existingDescriptor: Int32?,
        existingMetadata: stat?
    ) throws {
        let prepared: PreparedStorage
        switch intent {
        case .readExisting:
            guard let existingDescriptor, let existingMetadata else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            if (existingMetadata.st_mode & S_IFMT) == S_IFDIR {
                prepared = try Self.retainReadDirectory(
                    parentDescriptor: parentDescriptor,
                    contentDescriptor: existingDescriptor
                )
            } else {
                prepared = try Self.stageReadFile(
                    sourceDescriptor: existingDescriptor,
                    expectedMetadata: existingMetadata
                )
            }
        case .writeFile:
            guard existingDescriptor == nil else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            prepared = try Self.stageOutput(
                parentDescriptor: parentDescriptor,
                mode: .stagedFile
            )
        case .writeDestination:
            guard existingDescriptor == nil else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            prepared = try Self.stageOutput(
                parentDescriptor: parentDescriptor,
                mode: .stagedDirectory
            )
        }

        self.parentDescriptor = prepared.parentDescriptor
        self.contentDescriptor = prepared.contentDescriptor
        self.finalName = finalName
        stagingName = prepared.stagingName
        mode = prepared.mode
    }

    deinit {
        cleanupStaging()
        close(contentDescriptor)
        close(parentDescriptor)
    }

    var invocationPath: String {
        switch mode {
        case .readFile:
            return Self.providerInputName
        case .stagedFile:
            return Self.providerOutputName
        case .readDirectory, .stagedDirectory:
            return "."
        }
    }

    var workingDirectoryDescriptor: Int32? {
        contentDescriptor
    }

    var descriptorBindings: [RuntimeInteractiveDescriptorBinding] {
        []
    }

    func validateArchiveOutput() throws {
        try lock.withLock {
            guard mode == .stagedFile, !finalized else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The archive output is not a pinned regular file."
                )
            }
            let names = try RuntimeHostTreePolicy.validate(
                directoryDescriptor: contentDescriptor
            )
            guard names == [Self.providerOutputName] else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The archive output did not contain exactly one bounded regular file."
                )
            }
            let descriptor = openat(
                contentDescriptor,
                Self.providerOutputName,
                O_RDWR | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The archive output is not a pinned regular file."
                )
            }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The archive output is not a private regular file."
                )
            }
            try RuntimeTarArchivePolicy.normalizeExportedArchive(
                fileDescriptor: descriptor
            )
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid(),
                  metadata.st_nlink == 1 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The archive output is not a private regular file."
                )
            }
            validatedOutputSnapshot = metadata
        }
    }

    func validateCopyOutput() throws {
        guard mode == .stagedDirectory else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        let names = try RuntimeHostTreePolicy.validate(
            directoryDescriptor: contentDescriptor
        )
        guard names.count == 1 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The copy result did not contain exactly one bounded output tree."
            )
        }
    }

    func finalizeOutput() throws {
        try lock.withLock {
            guard !finalized else { return }
            switch mode {
            case .readFile, .readDirectory:
                finalized = true
            case .stagedFile:
                guard let validatedOutputSnapshot,
                      let stagingName else {
                    throw RuntimeInteractiveError.unsafeHostPath
                }
                var metadata = stat()
                guard fstatat(
                          contentDescriptor,
                          Self.providerOutputName,
                          &metadata,
                          AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_uid == geteuid(),
                      metadata.st_nlink == 1,
                      Self.sameSnapshot(metadata, validatedOutputSnapshot),
                      renameatx_np(
                          contentDescriptor,
                          Self.providerOutputName,
                          parentDescriptor,
                          finalName,
                          UInt32(RENAME_EXCL)
                      ) == 0,
                      unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR) == 0 else {
                    throw RuntimeInteractiveError.unsafeHostPath
                }
                finalized = true
            case .stagedDirectory:
                let names = try RuntimeHostTreePolicy.validate(
                    directoryDescriptor: contentDescriptor
                )
                guard names.count == 1,
                      renameatx_np(
                          contentDescriptor,
                          names[0],
                          parentDescriptor,
                          finalName,
                          UInt32(RENAME_EXCL)
                      ) == 0,
                      let stagingName,
                      unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR) == 0 else {
                    throw RuntimeInteractiveError.unsafeHostPath
                }
                finalized = true
            }
        }
    }

    private func cleanupStaging() {
        lock.withLock {
            guard !finalized, let stagingName else { return }
            switch mode {
            case .readFile:
                _ = fchmod(contentDescriptor, S_IRWXU)
                RuntimeHostTreePolicy.removeContents(
                    directoryDescriptor: contentDescriptor
                )
                _ = unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR)
            case .stagedFile, .stagedDirectory:
                RuntimeHostTreePolicy.removeContents(
                    directoryDescriptor: contentDescriptor
                )
                _ = unlinkat(parentDescriptor, stagingName, AT_REMOVEDIR)
            case .readDirectory:
                break
            }
        }
    }

    private static func retainReadDirectory(
        parentDescriptor: Int32,
        contentDescriptor: Int32
    ) throws -> PreparedStorage {
        let retainedParent = try duplicate(parentDescriptor)
        do {
            return PreparedStorage(
                parentDescriptor: retainedParent,
                contentDescriptor: try duplicate(contentDescriptor),
                stagingName: nil,
                mode: .readDirectory
            )
        } catch {
            close(retainedParent)
            throw error
        }
    }

    private static func stageReadFile(
        sourceDescriptor: Int32,
        expectedMetadata: stat
    ) throws -> PreparedStorage {
        let temporaryRoot = try openPrivateTemporaryRoot()
        do {
            let staged = try createStagedDirectory(in: temporaryRoot)
            do {
                try materializeReadFile(
                    sourceDescriptor: sourceDescriptor,
                    expectedMetadata: expectedMetadata,
                    directoryDescriptor: staged.descriptor
                )
                return PreparedStorage(
                    parentDescriptor: temporaryRoot,
                    contentDescriptor: staged.descriptor,
                    stagingName: staged.name,
                    mode: .readFile
                )
            } catch {
                _ = fchmod(staged.descriptor, S_IRWXU)
                RuntimeHostTreePolicy.removeContents(
                    directoryDescriptor: staged.descriptor
                )
                close(staged.descriptor)
                _ = unlinkat(temporaryRoot, staged.name, AT_REMOVEDIR)
                throw error
            }
        } catch {
            close(temporaryRoot)
            throw error
        }
    }

    private static func stageOutput(
        parentDescriptor: Int32,
        mode: Mode
    ) throws -> PreparedStorage {
        let retainedParent = try duplicate(parentDescriptor)
        do {
            let staged = try createStagedDirectory(in: retainedParent)
            return PreparedStorage(
                parentDescriptor: retainedParent,
                contentDescriptor: staged.descriptor,
                stagingName: staged.name,
                mode: mode
            )
        } catch {
            close(retainedParent)
            throw error
        }
    }

    private static func duplicate(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard duplicate >= 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        return duplicate
    }

    private static func openPrivateTemporaryRoot() throws -> Int32 {
        let path = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).standardizedFileURL.path
        let descriptor = open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            close(descriptor)
            throw RuntimeInteractiveError.unsafeHostPath
        }
        return descriptor
    }

    private static func materializeReadFile(
        sourceDescriptor: Int32,
        expectedMetadata: stat,
        directoryDescriptor: Int32
    ) throws {
        var before = stat()
        guard fstat(sourceDescriptor, &before) == 0,
              sameSnapshot(before, expectedMetadata),
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) <= RuntimeHostTreePolicy.maximumBytes else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        let destination = openat(
            directoryDescriptor,
            providerInputName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard destination >= 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        var keepDestination = false
        defer {
            close(destination)
            if !keepDestination {
                _ = unlinkat(directoryDescriptor, providerInputName, 0)
            }
        }

        try copyExactBytes(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destination,
            byteCount: before.st_size
        )
        var after = stat()
        var copied = stat()
        guard fstat(sourceDescriptor, &after) == 0,
              sameSnapshot(before, after),
              fstat(destination, &copied) == 0,
              (copied.st_mode & S_IFMT) == S_IFREG,
              copied.st_size == before.st_size,
              fsync(destination) == 0,
              fchmod(destination, S_IRUSR) == 0,
              fsync(directoryDescriptor) == 0,
              fchmod(directoryDescriptor, S_IRUSR | S_IXUSR) == 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
        keepDestination = true
    }

    private static func copyExactBytes(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        byteCount: off_t
    ) throws {
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while offset < byteCount {
            let requested = min(buffer.count, Int(byteCount - offset))
            let count = pread(
                sourceDescriptor,
                &buffer,
                requested,
                offset
            )
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes {
                    pwrite(
                        destinationDescriptor,
                        $0.baseAddress!.advanced(by: written),
                        count - written,
                        offset + off_t(written)
                    )
                }
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else {
                    throw RuntimeInteractiveError.unsafeHostPath
                }
                written += result
            }
            offset += off_t(count)
        }
        var extra: UInt8 = 0
        let extraCount = pread(sourceDescriptor, &extra, 1, byteCount)
        guard extraCount == 0 else {
            throw RuntimeInteractiveError.unsafeHostPath
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func createStagedDirectory(
        in parentDescriptor: Int32
    ) throws -> (name: String, descriptor: Int32) {
        for _ in 0..<16 {
            let name = ".hostwright-\(UUID().uuidString.lowercased()).stage"
            if mkdirat(parentDescriptor, name, S_IRWXU) == 0 {
                let descriptor = openat(
                    parentDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    _ = unlinkat(parentDescriptor, name, AT_REMOVEDIR)
                    throw RuntimeInteractiveError.unsafeHostPath
                }
                return (name, descriptor)
            }
            guard errno == EEXIST else {
                throw RuntimeInteractiveError.unsafeHostPath
            }
        }
        throw RuntimeInteractiveError.unsafeHostPath
    }
}

enum RuntimeHostTreePolicy {
    static let maximumEntries = 100_000
    static let maximumBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024

    static func validate(directoryDescriptor: Int32) throws -> [String] {
        var entryCount = 0
        var totalBytes: UInt64 = 0
        let names = try validateDirectory(
            directoryDescriptor,
            entryCount: &entryCount,
            totalBytes: &totalBytes
        )
        return names.sorted()
    }

    static func removeContents(directoryDescriptor: Int32) {
        guard let names = try? directoryEntries(directoryDescriptor) else { return }
        for name in names {
            var metadata = stat()
            guard fstatat(
                directoryDescriptor,
                name,
                &metadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0 else {
                continue
            }
            if (metadata.st_mode & S_IFMT) == S_IFDIR {
                let child = openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                if child >= 0 {
                    removeContents(directoryDescriptor: child)
                    close(child)
                }
                _ = unlinkat(directoryDescriptor, name, AT_REMOVEDIR)
            } else {
                _ = unlinkat(directoryDescriptor, name, 0)
            }
        }
    }

    private static func validateDirectory(
        _ descriptor: Int32,
        entryCount: inout Int,
        totalBytes: inout UInt64
    ) throws -> [String] {
        let names = try directoryEntries(descriptor)
        for name in names {
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The copied tree has too many entries."
                )
            }
            let child = openat(
                descriptor,
                name,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The copied tree contains a symbolic link or an unreadable entry."
                )
            }
            defer { close(child) }
            var metadata = stat()
            guard fstat(child, &metadata) == 0 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The copied tree contains an unreadable entry."
                )
            }
            switch metadata.st_mode & S_IFMT {
            case S_IFREG:
                guard metadata.st_size >= 0 else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The copied tree contains an invalid file."
                    )
                }
                totalBytes += UInt64(metadata.st_size)
                guard totalBytes <= maximumBytes else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The copied tree exceeds the safety limit."
                    )
                }
            case S_IFDIR:
                _ = try validateDirectory(
                    child,
                    entryCount: &entryCount,
                    totalBytes: &totalBytes
                )
            default:
                throw RuntimeInteractiveError.unsafeArchive(
                    "The copied tree contains an unsupported entry type."
                )
            }
        }
        return names
    }

    private static func directoryEntries(_ descriptor: Int32) throws -> [String] {
        let duplicate = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw RuntimeInteractiveError.unsafeArchive(
                "The copied tree could not be opened safely."
            )
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }
            guard !name.isEmpty,
                  !name.contains("/"),
                  !name.contains("\0") else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The copied tree contains an unsafe entry name."
                )
            }
            names.append(name)
        }
        guard errno == 0 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The copied tree could not be enumerated safely."
            )
        }
        return names.sorted()
    }
}

public enum RuntimeTarArchivePolicy {
    public static let maximumEntries = 100_000
    public static let maximumExpandedBytes: UInt64 = 64 * 1_024 * 1_024 * 1_024

    private static let maximumPAXPayloadBytes = 64 * 1_024
    private static let maximumPAXValueBytes = 4 * 1_024

    private struct FileRewrite {
        let offset: UInt64
        let data: Data
    }

    private struct FileInsertion {
        let offset: UInt64
        let data: Data
    }

    private struct ArchiveNormalizationPlan {
        var rewrites: [FileRewrite] = []
        var insertions: [FileInsertion] = []
    }

    private struct PAXRecord: Equatable {
        let key: String
        let value: String
    }

    private struct PendingPAX {
        let headerOffset: UInt64
        let payloadOffset: UInt64
        let paddedPayloadSize: UInt64
        let header: Data
        let records: [PAXRecord]

        var path: String? {
            records.first(where: { $0.key == "path" })?.value
        }

        var linkPath: String? {
            records.first(where: { $0.key == "linkpath" })?.value
        }
    }

    public static func validate(_ archive: Data) throws {
        guard archive.count % 512 == 0 else {
            throw RuntimeInteractiveError.unsafeArchive("The tar stream is truncated.")
        }
        var offset = 0
        var entryCount = 0
        var expandedBytes: UInt64 = 0
        var pendingPAX: [PAXRecord]?
        while offset + 512 <= archive.count {
            let header = archive[offset..<(offset + 512)]
            if header.allSatisfy({ $0 == 0 }) {
                guard pendingPAX == nil else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream contains an orphaned PAX header."
                    )
                }
                guard offset + 1_024 <= archive.count,
                      archive[offset...].allSatisfy({ $0 == 0 }) else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream has an invalid terminator."
                    )
                }
                return
            }
            try validateHeaderChecksum(header)
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw RuntimeInteractiveError.unsafeArchive("The tar stream has too many entries.")
            }
            let name = try archiveString(header, range: 0..<100)
            let prefix = try archiveString(header, range: 345..<500)
            let headerPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let type = header[header.index(header.startIndex, offsetBy: 156)]
            let size = try archiveOctal(header, range: 124..<136)
            expandedBytes += size
            guard expandedBytes <= maximumExpandedBytes else {
                throw RuntimeInteractiveError.unsafeArchive("The tar stream expands beyond the safety limit.")
            }
            let paddedSize = ((size + 511) / 512) * 512
            guard paddedSize <= UInt64(Int.max),
                  offset <= archive.count - 512,
                  Int(paddedSize) <= archive.count - offset - 512 else {
                throw RuntimeInteractiveError.unsafeArchive("The tar entry payload is truncated.")
            }

            if type == 120 {
                guard pendingPAX == nil else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream contains consecutive PAX headers."
                    )
                }
                try validateArchivePath(headerPath)
                guard size <= UInt64(maximumPAXPayloadBytes) else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The PAX payload exceeds the safety limit."
                    )
                }
                let payloadStart = offset + 512
                let payloadEnd = payloadStart + Int(size)
                pendingPAX = try parsePAXRecords(
                    Data(archive[payloadStart..<payloadEnd])
                )
                offset += 512 + Int(paddedSize)
                continue
            }

            guard type == 0 || type == 48 || type == 53 || type == 49 || type == 50 else {
                throw RuntimeInteractiveError.unsafeArchive("The tar stream contains an unsupported entry type.")
            }
            try validateArchivePath(headerPath, entryType: type)
            let pax = pendingPAX
            pendingPAX = nil
            let effectivePath =
                pax?.first(where: { $0.key == "path" })?.value ?? headerPath
            try validateArchivePath(effectivePath, entryType: type)
            let paxLinkPath =
                pax?.first(where: { $0.key == "linkpath" })?.value
            guard paxLinkPath == nil || type == 49 || type == 50 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "A PAX linkpath is attached to a non-link entry."
                )
            }
            let headerLinkName = try archiveString(header, range: 157..<257)
            if type == 49 || type == 50 {
                try validateArchiveLink(
                    paxLinkPath ?? headerLinkName,
                    from: effectivePath,
                    type: type
                )
            }
            offset += 512 + Int(paddedSize)
        }
        throw RuntimeInteractiveError.unsafeArchive("The tar stream has no terminating block.")
    }

    public static func validate(fileAt path: String) throws {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The exported archive could not be opened safely."
            )
        }
        defer { close(descriptor) }
        try validate(fileDescriptor: descriptor)
    }

    public static func validate(fileDescriptor descriptor: Int32) throws {
        _ = try scanFileArchive(
            descriptor: descriptor,
            normalizeGuestRootLinks: false
        )
    }

    static func normalizeExportedArchive(fileDescriptor descriptor: Int32) throws {
        let plan = try scanFileArchive(
            descriptor: descriptor,
            normalizeGuestRootLinks: true
        )
        for rewrite in plan.rewrites {
            try writeExact(
                rewrite.data,
                fileDescriptor: descriptor,
                offset: rewrite.offset
            )
        }
        if !plan.insertions.isEmpty {
            try applyInsertions(
                plan.insertions,
                fileDescriptor: descriptor
            )
        }
        if (!plan.rewrites.isEmpty || !plan.insertions.isEmpty),
           fsync(descriptor) != 0 {
            throw RuntimeInteractiveError.unsafeArchive(
                "The normalized tar stream could not be synchronized."
            )
        }
        _ = try scanFileArchive(
            descriptor: descriptor,
            normalizeGuestRootLinks: false
        )
    }

    private static func scanFileArchive(
        descriptor: Int32,
        normalizeGuestRootLinks: Bool
    ) throws -> ArchiveNormalizationPlan {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size % 512 == 0 else {
            throw RuntimeInteractiveError.unsafeArchive("The tar stream is truncated.")
        }

        let fileSize = UInt64(metadata.st_size)
        var offset: UInt64 = 0
        var entryCount = 0
        var expandedBytes: UInt64 = 0
        var plan = ArchiveNormalizationPlan()
        var pendingPAX: PendingPAX?
        while offset + 512 <= fileSize {
            var bytes = [UInt8](repeating: 0, count: 512)
            let count = pread(descriptor, &bytes, bytes.count, off_t(offset))
            guard count == bytes.count else {
                throw RuntimeInteractiveError.unsafeArchive("The tar stream is truncated.")
            }
            let header = Data(bytes)
            if header.allSatisfy({ $0 == 0 }) {
                guard pendingPAX == nil else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream contains an orphaned PAX header."
                    )
                }
                try validateFileTerminator(
                    descriptor: descriptor,
                    offset: offset,
                    fileSize: fileSize
                )
                return plan
            }
            try validateHeaderChecksum(header[header.startIndex..<header.endIndex])
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw RuntimeInteractiveError.unsafeArchive("The tar stream has too many entries.")
            }
            let name = try archiveString(header[header.startIndex..<header.endIndex], range: 0..<100)
            let prefix = try archiveString(
                header[header.startIndex..<header.endIndex],
                range: 345..<500
            )
            let headerPath = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let type = header[156]
            let size = try archiveOctal(
                header[header.startIndex..<header.endIndex],
                range: 124..<136
            )
            expandedBytes += size
            guard expandedBytes <= maximumExpandedBytes else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar stream expands beyond the safety limit."
                )
            }
            let paddedSize = ((size + 511) / 512) * 512
            guard offset + 512 + paddedSize <= fileSize else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar entry payload is truncated."
                )
            }

            if type == 120 {
                guard pendingPAX == nil else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream contains consecutive PAX headers."
                    )
                }
                try validateArchivePath(headerPath)
                guard size <= UInt64(maximumPAXPayloadBytes) else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The PAX payload exceeds the safety limit."
                    )
                }
                var payload = [UInt8](repeating: 0, count: Int(size))
                if !payload.isEmpty {
                    let payloadCount = pread(
                        descriptor,
                        &payload,
                        payload.count,
                        off_t(offset + 512)
                    )
                    guard payloadCount == payload.count else {
                        throw RuntimeInteractiveError.unsafeArchive(
                            "The PAX payload is truncated."
                        )
                    }
                }
                pendingPAX = PendingPAX(
                    headerOffset: offset,
                    payloadOffset: offset + 512,
                    paddedPayloadSize: paddedSize,
                    header: header,
                    records: try parsePAXRecords(Data(payload))
                )
                offset += 512 + paddedSize
                continue
            }

            guard type == 0 || type == 48 || type == 53 || type == 49 || type == 50 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar stream contains an unsupported entry type."
                )
            }
            try validateArchivePath(headerPath, entryType: type)
            let pax = pendingPAX
            pendingPAX = nil
            let effectivePath = pax?.path ?? headerPath
            try validateArchivePath(effectivePath, entryType: type)
            let paxLinkPath = pax?.linkPath
            guard paxLinkPath == nil || type == 49 || type == 50 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "A PAX linkpath is attached to a non-link entry."
                )
            }
            let headerLinkName = try archiveString(
                header[header.startIndex..<header.endIndex],
                range: 157..<257
            )
            if type == 49 || type == 50 {
                let effectiveLink = paxLinkPath ?? headerLinkName
                if effectiveLink.hasPrefix("/"), normalizeGuestRootLinks {
                    let normalized = try normalizedGuestRootLink(
                        effectiveLink,
                        from: effectivePath,
                        type: type
                    )
                    if let pax, paxLinkPath != nil {
                        plan.rewrites.append(
                            contentsOf: try paxRewrites(
                                pax,
                                normalizedLinkPath: normalized
                            )
                        )
                        plan.rewrites.append(
                            FileRewrite(
                                offset: offset,
                                data: try rewrittenLinkHeader(
                                    header,
                                    target: normalized.utf8.count <= 100
                                        ? normalized
                                        : "."
                                )
                            )
                        )
                    } else {
                        if normalized.utf8.count <= 100 {
                            plan.rewrites.append(
                                FileRewrite(
                                    offset: offset,
                                    data: try rewrittenLinkHeader(
                                        header,
                                        target: normalized
                                    )
                                )
                            )
                        } else {
                            plan.insertions.append(
                                FileInsertion(
                                    offset: offset,
                                    data: try synthesizedPAXHeader(
                                        linkPath: normalized,
                                        entryOffset: offset
                                    )
                                )
                            )
                            plan.rewrites.append(
                                FileRewrite(
                                    offset: offset,
                                    data: try rewrittenLinkHeader(
                                        header,
                                        target: "."
                                    )
                                )
                            )
                        }
                    }
                } else {
                    try validateArchiveLink(
                        effectiveLink,
                        from: effectivePath,
                        type: type
                    )
                }
            }
            offset += 512 + paddedSize
        }
        throw RuntimeInteractiveError.unsafeArchive("The tar stream has no terminating block.")
    }

    private static func parsePAXRecords(_ payload: Data) throws -> [PAXRecord] {
        guard !payload.isEmpty else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The PAX payload is empty."
            )
        }
        var offset = 0
        var records: [PAXRecord] = []
        var keys = Set<String>()
        while offset < payload.count {
            guard let space = payload[offset...].firstIndex(of: 0x20),
                  space > offset else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record length is malformed."
                )
            }
            let digits = payload[offset..<space]
            guard digits.first != 0x30,
                  digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record length is malformed."
                )
            }
            var length = 0
            for byte in digits {
                let digit = Int(byte - 0x30)
                guard length <= (Int.max - digit) / 10 else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The PAX record length is malformed."
                    )
                }
                length = length * 10 + digit
            }
            guard length > digits.count + 3,
                  length <= payload.count - offset else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record length is malformed."
                )
            }
            let end = offset + length
            guard payload[end - 1] == 0x0a else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record is not newline terminated."
                )
            }
            let contentStart = space + 1
            let contentEnd = end - 1
            guard let equals = payload[contentStart..<contentEnd]
                .firstIndex(of: 0x3d),
                  equals > contentStart else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record is malformed."
                )
            }
            guard let key = String(
                      data: Data(payload[contentStart..<equals]),
                      encoding: .utf8
                  ),
                  key == "path" || key == "linkpath",
                  keys.insert(key).inserted,
                  let value = String(
                      data: Data(payload[(equals + 1)..<contentEnd]),
                      encoding: .utf8
                  ),
                  !value.isEmpty,
                  value.utf8.count <= maximumPAXValueBytes,
                  value.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The PAX record contains an unsupported or unsafe value."
                )
            }
            records.append(PAXRecord(key: key, value: value))
            offset = end
        }
        return records
    }

    private static func paxRewrites(
        _ pax: PendingPAX,
        normalizedLinkPath: String
    ) throws -> [FileRewrite] {
        let records = pax.records.map { record in
            record.key == "linkpath"
                ? PAXRecord(key: record.key, value: normalizedLinkPath)
                : record
        }
        let payload = encodePAXRecords(records)
        let paddedSize = ((payload.count + 511) / 512) * 512
        guard UInt64(paddedSize) == pax.paddedPayloadSize else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The normalized PAX payload cannot preserve the archive layout."
            )
        }
        var header = pax.header
        writeHeaderSize(UInt64(payload.count), into: &header)
        writeHeaderChecksum(&header)
        var paddedPayload = payload
        paddedPayload.append(
            Data(repeating: 0, count: paddedSize - payload.count)
        )
        return [
            FileRewrite(offset: pax.headerOffset, data: header),
            FileRewrite(offset: pax.payloadOffset, data: paddedPayload)
        ]
    }

    private static func rewrittenLinkHeader(
        _ header: Data,
        target: String
    ) throws -> Data {
        let bytes = Array(target.utf8)
        guard !bytes.isEmpty, bytes.count <= 100 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The normalized tar link target exceeds the header limit."
            )
        }
        var rewritten = header
        rewritten.replaceSubrange(
            157..<257,
            with: repeatElement(0, count: 100)
        )
        rewritten.replaceSubrange(
            157..<(157 + bytes.count),
            with: bytes
        )
        writeHeaderChecksum(&rewritten)
        return rewritten
    }

    private static func synthesizedPAXHeader(
        linkPath: String,
        entryOffset: UInt64
    ) throws -> Data {
        let payload = encodePAXRecords([
            PAXRecord(key: "linkpath", value: linkPath)
        ])
        guard payload.count <= maximumPAXPayloadBytes else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The normalized PAX payload exceeds the safety limit."
            )
        }
        var header = Data(repeating: 0, count: 512)
        try writeArchiveField(
            "PaxHeaders.hostwright/\(String(format: "%016llx", entryOffset))",
            into: &header,
            at: 0,
            fieldSize: 100
        )
        try writeArchiveField(
            "0000600",
            into: &header,
            at: 100,
            fieldSize: 8
        )
        try writeArchiveField(
            "0000000",
            into: &header,
            at: 108,
            fieldSize: 8
        )
        try writeArchiveField(
            "0000000",
            into: &header,
            at: 116,
            fieldSize: 8
        )
        writeHeaderSize(UInt64(payload.count), into: &header)
        try writeArchiveField(
            "00000000000",
            into: &header,
            at: 136,
            fieldSize: 12
        )
        header[156] = 120
        try writeArchiveField(
            "ustar",
            into: &header,
            at: 257,
            fieldSize: 6
        )
        try writeArchiveField(
            "00",
            into: &header,
            at: 263,
            fieldSize: 2,
            requireTerminator: false
        )
        writeHeaderChecksum(&header)

        let paddedSize = ((payload.count + 511) / 512) * 512
        var insertion = header
        insertion.append(payload)
        insertion.append(
            Data(repeating: 0, count: paddedSize - payload.count)
        )
        return insertion
    }

    private static func writeArchiveField(
        _ value: String,
        into header: inout Data,
        at offset: Int,
        fieldSize: Int,
        requireTerminator: Bool = true
    ) throws {
        let bytes = Array(value.utf8)
        let limit = requireTerminator ? fieldSize - 1 : fieldSize
        guard bytes.count <= limit,
              offset >= 0,
              fieldSize > 0,
              offset <= header.count - fieldSize else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The synthesized PAX header exceeds a field limit."
            )
        }
        header.replaceSubrange(
            offset..<(offset + fieldSize),
            with: repeatElement(0, count: fieldSize)
        )
        header.replaceSubrange(
            offset..<(offset + bytes.count),
            with: bytes
        )
    }

    private static func applyInsertions(
        _ insertions: [FileInsertion],
        fileDescriptor descriptor: Int32
    ) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar stream cannot be expanded safely."
            )
        }
        let originalSize = UInt64(metadata.st_size)
        let sorted = insertions.sorted { $0.offset < $1.offset }
        var priorOffset: UInt64?
        var addedBytes: UInt64 = 0
        for insertion in sorted {
            guard insertion.offset % 512 == 0,
                  insertion.offset <= originalSize,
                  insertion.data.count > 0,
                  insertion.data.count % 512 == 0,
                  insertion.offset != priorOffset,
                  UInt64(insertion.data.count) <= UInt64.max - addedBytes else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar metadata insertion plan is invalid."
                )
            }
            priorOffset = insertion.offset
            addedBytes += UInt64(insertion.data.count)
        }
        guard originalSize <= UInt64(Int64.max) - addedBytes else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The normalized tar stream is too large."
            )
        }
        let expandedSize = originalSize + addedBytes
        guard ftruncate(descriptor, off_t(expandedSize)) == 0 else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar stream could not be expanded safely."
            )
        }

        var sourceEnd = originalSize
        var destinationEnd = expandedSize
        for insertion in sorted.reversed() {
            try moveFileRangeBackward(
                fileDescriptor: descriptor,
                sourceStart: insertion.offset,
                sourceEnd: sourceEnd,
                destinationEnd: destinationEnd
            )
            let movedBytes = sourceEnd - insertion.offset
            destinationEnd -= movedBytes
            destinationEnd -= UInt64(insertion.data.count)
            try writeExact(
                insertion.data,
                fileDescriptor: descriptor,
                offset: destinationEnd
            )
            sourceEnd = insertion.offset
        }
    }

    private static func moveFileRangeBackward(
        fileDescriptor descriptor: Int32,
        sourceStart: UInt64,
        sourceEnd: UInt64,
        destinationEnd: UInt64
    ) throws {
        let byteCount = sourceEnd - sourceStart
        guard destinationEnd >= byteCount else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar metadata insertion plan is invalid."
            )
        }
        let destinationStart = destinationEnd - byteCount
        var remaining = byteCount
        while remaining > 0 {
            let chunkSize = Int(min(remaining, UInt64(256 * 1_024)))
            let chunkOffset = remaining - UInt64(chunkSize)
            let data = try readExact(
                byteCount: chunkSize,
                fileDescriptor: descriptor,
                offset: sourceStart + chunkOffset
            )
            try writeExact(
                data,
                fileDescriptor: descriptor,
                offset: destinationStart + chunkOffset
            )
            remaining = chunkOffset
        }
    }

    private static func readExact(
        byteCount: Int,
        fileDescriptor descriptor: Int32,
        offset: UInt64
    ) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var consumed = 0
        while consumed < byteCount {
            let count = bytes.withUnsafeMutableBytes { buffer in
                pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: consumed),
                    byteCount - consumed,
                    off_t(offset + UInt64(consumed))
                )
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar stream could not be shifted safely."
                )
            }
            consumed += count
        }
        return Data(bytes)
    }

    private static func writeExact(
        _ data: Data,
        fileDescriptor descriptor: Int32,
        offset: UInt64
    ) throws {
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let count = pwrite(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written,
                    off_t(offset + UInt64(written))
                )
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw RuntimeInteractiveError.unsafeArchive(
                        "The tar stream could not be shifted safely."
                    )
                }
                written += count
            }
        }
    }

    private static func encodePAXRecords(_ records: [PAXRecord]) -> Data {
        var payload = Data()
        for record in records {
            let body = Data("\(record.key)=\(record.value)\n".utf8)
            var length = body.count + 2
            while true {
                let candidate = String(length).utf8.count + 1 + body.count
                if candidate == length {
                    break
                }
                length = candidate
            }
            payload.append(Data("\(length) ".utf8))
            payload.append(body)
        }
        return payload
    }

    private static func writeHeaderSize(_ size: UInt64, into header: inout Data) {
        header.replaceSubrange(124..<136, with: repeatElement(0, count: 12))
        let bytes = Array(String(format: "%011llo", size).utf8)
        header.replaceSubrange(124..<(124 + bytes.count), with: bytes)
    }

    private static func validateHeaderChecksum(
        _ header: Data.SubSequence
    ) throws {
        guard header.count == 512 else {
            throw RuntimeInteractiveError.unsafeArchive("The tar header is truncated.")
        }
        let rawChecksum = try archiveString(header, range: 148..<156)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard !rawChecksum.isEmpty,
              rawChecksum.allSatisfy({ ("0"..."7").contains($0) }),
              let expected = UInt64(rawChecksum, radix: 8) else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar header has an invalid checksum."
            )
        }
        let actual = header.enumerated().reduce(UInt64(0)) { checksum, element in
            checksum + UInt64((148..<156).contains(element.offset) ? 0x20 : element.element)
        }
        guard actual == expected else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar header checksum does not match."
            )
        }
    }

    private static func validateFileTerminator(
        descriptor: Int32,
        offset: UInt64,
        fileSize: UInt64
    ) throws {
        guard offset + 1_024 <= fileSize else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar stream has an invalid terminator."
            )
        }
        var cursor = offset
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while cursor < fileSize {
            let requested = min(buffer.count, Int(fileSize - cursor))
            let count = pread(descriptor, &buffer, requested, off_t(cursor))
            guard count == requested,
                  buffer.prefix(count).allSatisfy({ $0 == 0 }) else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar stream has an invalid terminator."
                )
            }
            cursor += UInt64(count)
        }
    }

    private static func validateArchivePath(
        _ path: String,
        entryType: UInt8? = nil
    ) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw RuntimeInteractiveError.unsafeArchive("The tar stream contains an unsafe path.")
        }
        let pathWithoutDirectoryTerminator: Substring
        if entryType == 53, path.hasSuffix("/") {
            guard !path.hasSuffix("//") else {
                throw RuntimeInteractiveError.unsafeArchive(
                    "The tar stream contains path traversal."
                )
            }
            pathWithoutDirectoryTerminator = path.dropLast()
        } else {
            pathWithoutDirectoryTerminator = path[...]
        }
        let components = pathWithoutDirectoryTerminator.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RuntimeInteractiveError.unsafeArchive("The tar stream contains path traversal.")
        }
    }

    private static func validateArchiveLink(
        _ target: String,
        from path: String,
        type: UInt8
    ) throws {
        guard !target.isEmpty,
              !target.hasPrefix("/"),
              !target.contains("\\"),
              !target.contains("\0") else {
            throw RuntimeInteractiveError.unsafeArchive("The tar stream contains an unsafe link target.")
        }
        if type == 49 {
            try validateArchivePath(target)
            return
        }
        var depth = max(0, path.split(separator: "/").count - 1)
        for component in target.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." {
                continue
            }
            if component == ".." {
                guard depth > 0 else {
                    throw RuntimeInteractiveError.unsafeArchive("The tar link escapes the archive root.")
                }
                depth -= 1
            } else {
                depth += 1
            }
        }
    }

    private static func normalizedGuestRootLink(
        _ target: String,
        from path: String,
        type: UInt8
    ) throws -> String {
        guard target.hasPrefix("/"),
              !target.hasPrefix("//"),
              !target.contains("\\"),
              !target.contains("\0") else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar stream contains an unsafe link target."
            )
        }
        let targetComponents = target.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !targetComponents.isEmpty,
              targetComponents.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw RuntimeInteractiveError.unsafeArchive(
                "The tar stream contains an unsafe link target."
            )
        }
        if type == 49 {
            let normalized = targetComponents.joined(separator: "/")
            try validateArchivePath(normalized)
            return normalized
        }

        let parentComponents = path.split(separator: "/").dropLast()
        var commonCount = 0
        while commonCount < parentComponents.count,
              commonCount < targetComponents.count,
              parentComponents[parentComponents.index(
                  parentComponents.startIndex,
                  offsetBy: commonCount
              )] == targetComponents[targetComponents.index(
                  targetComponents.startIndex,
                  offsetBy: commonCount
              )] {
            commonCount += 1
        }
        var relativeComponents = Array(
            repeating: "..",
            count: parentComponents.count - commonCount
        )
        relativeComponents.append(
            contentsOf: targetComponents.dropFirst(commonCount).map(String.init)
        )
        let normalized = relativeComponents.isEmpty
            ? "."
            : relativeComponents.joined(separator: "/")
        try validateArchiveLink(normalized, from: path, type: type)
        return normalized
    }

    private static func writeHeaderChecksum(_ header: inout Data) {
        header.replaceSubrange(148..<156, with: repeatElement(0x20, count: 8))
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let bytes = Array(String(format: "%06llo", checksum).utf8)
        header.replaceSubrange(148..<(148 + bytes.count), with: bytes)
        header[154] = 0
        header[155] = 0x20
    }

    private static func archiveString(
        _ header: Data.SubSequence,
        range: Range<Int>
    ) throws -> String {
        let bytes = header.dropFirst(range.lowerBound).prefix(range.count).prefix { $0 != 0 }
        guard let value = String(data: Data(bytes), encoding: .utf8) else {
            throw RuntimeInteractiveError.unsafeArchive("The tar header is not UTF-8.")
        }
        return value
    }

    private static func archiveOctal(
        _ header: Data.SubSequence,
        range: Range<Int>
    ) throws -> UInt64 {
        let raw = try archiveString(header, range: range)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard raw.isEmpty || raw.allSatisfy({ ("0"..."7").contains($0) }),
              let value = raw.isEmpty ? 0 : UInt64(raw, radix: 8) else {
            throw RuntimeInteractiveError.unsafeArchive("The tar header has an invalid size.")
        }
        return value
    }
}
