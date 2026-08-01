import CryptoKit
import Darwin
import Foundation
import HostwrightCore

public enum DaemonLifecycleOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case status
    case install
    case validate
    case bootstrap
    case start
    case stop
    case kickstart
    case upgrade
    case rollback
    case disable
    case repair
    case uninstall
}

public enum DaemonLifecycleCheckpoint: String, Codable, Equatable, Sendable {
    case intentRecorded = "intent-recorded"
    case rollbackPublished = "rollback-published"
    case serviceStopped = "service-stopped"
    case propertyListPublished = "property-list-published"
    case disabledStatePublished = "disabled-state-published"
    case serviceStarted = "service-started"
    case verified
    case statusPublished = "status-published"
}

public enum DaemonLifecycleReadiness: String, Codable, Equatable, Sendable {
    case notInstalled = "not-installed"
    case stopped
    case running
    case disabled
    case recoveryRequired = "recovery-required"
}

public enum DaemonLifecycleReasonCode: String, Codable, Equatable, Sendable {
    case notInstalled = "daemon.not-installed"
    case installed = "daemon.installed"
    case validated = "daemon.validated"
    case bootstrapped = "daemon.bootstrapped"
    case started = "daemon.started"
    case stopped = "daemon.stopped"
    case kickstarted = "daemon.kickstarted"
    case upgraded = "daemon.upgraded"
    case rolledBack = "daemon.rolled-back"
    case disabled = "daemon.disabled"
    case repaired = "daemon.repaired"
    case recovered = "daemon.recovered"
    case uninstalled = "daemon.uninstalled"
    case recoveryRequired = "daemon.recovery-required"
}

public struct DaemonLifecycleStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let label: String
    public let domain: String
    public let readiness: DaemonLifecycleReadiness
    public let propertyListPath: String
    public let daemonExecutablePath: String?
    public let configPath: String?
    public let generation: Int?
    public let installationID: String?
    public let processID: Int32?
    public let pendingOperation: DaemonLifecycleOperation?
    public let reasonCode: DaemonLifecycleReasonCode

    public init(
        schemaVersion: Int = 1,
        label: String,
        domain: String,
        readiness: DaemonLifecycleReadiness,
        propertyListPath: String,
        daemonExecutablePath: String?,
        configPath: String?,
        generation: Int?,
        installationID: String?,
        processID: Int32?,
        pendingOperation: DaemonLifecycleOperation?,
        reasonCode: DaemonLifecycleReasonCode
    ) {
        self.schemaVersion = schemaVersion
        self.label = label
        self.domain = domain
        self.readiness = readiness
        self.propertyListPath = propertyListPath
        self.daemonExecutablePath = daemonExecutablePath
        self.configPath = configPath
        self.generation = generation
        self.installationID = installationID
        self.processID = processID
        self.pendingOperation = pendingOperation
        self.reasonCode = reasonCode
    }
}

public struct DaemonLifecycleResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operation: DaemonLifecycleOperation
    public let changed: Bool
    public let reasonCode: DaemonLifecycleReasonCode
    public let status: DaemonLifecycleStatus

    public init(
        schemaVersion: Int = 1,
        operation: DaemonLifecycleOperation,
        changed: Bool,
        reasonCode: DaemonLifecycleReasonCode,
        status: DaemonLifecycleStatus
    ) {
        self.schemaVersion = schemaVersion
        self.operation = operation
        self.changed = changed
        self.reasonCode = reasonCode
        self.status = status
    }
}

public struct DaemonLifecycleProcessResult: Equatable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitStatus: Int32, standardOutput: String, standardError: String) {
        self.exitStatus = exitStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static func success(_ output: String = "") -> Self {
        Self(exitStatus: 0, standardOutput: output, standardError: "")
    }

    public static var notFound: Self {
        Self(exitStatus: 113, standardOutput: "", standardError: "service not found")
    }

    public static func failure(_ status: Int32, _ message: String) -> Self {
        Self(exitStatus: status, standardOutput: "", standardError: message)
    }
}

public struct DaemonProcessIdentity: Equatable, Sendable {
    public let processID: Int32
    public let executablePath: String

    public init(processID: Int32, executablePath: String) {
        self.processID = processID
        self.executablePath = executablePath
    }
}

public struct DaemonLifecycleDependencies: @unchecked Sendable {
    public var runLaunchctl:
        ([String], SecureSubprocessCancellation) throws -> DaemonLifecycleProcessResult
    public var processInventory: () throws -> [DaemonProcessIdentity]
    public var timestamp: () -> String
    public var operationID: () -> String

    public init(
        runLaunchctl: @escaping (
            [String],
            SecureSubprocessCancellation
        ) throws -> DaemonLifecycleProcessResult,
        processInventory: @escaping () throws -> [DaemonProcessIdentity],
        timestamp: @escaping () -> String,
        operationID: @escaping () -> String
    ) {
        self.runLaunchctl = runLaunchctl
        self.processInventory = processInventory
        self.timestamp = timestamp
        self.operationID = operationID
    }

    public static let live = DaemonLifecycleDependencies(
        runLaunchctl: { arguments, cancellation in
            let result = try SecureSubprocessRunner().run(
                SecureSubprocessRequest(
                    executablePath: "/bin/launchctl",
                    arguments: arguments,
                    environment: SecureSubprocessEnvironment.currentUser,
                    timeoutMilliseconds: 30_000,
                    maximumStandardOutputBytes: 1_048_576,
                    maximumStandardErrorBytes: 1_048_576
                ),
                cancellation: cancellation
            )
            guard !result.standardOutputTruncated, !result.standardErrorTruncated else {
                throw DaemonLifecycleError.commandFailed(
                    arguments.joined(separator: " "),
                    result.exitStatus
                )
            }
            return DaemonLifecycleProcessResult(
                exitStatus: result.exitStatus,
                standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
                standardError: String(decoding: result.standardError, as: UTF8.self)
            )
        },
        processInventory: DaemonLifecycleDependencies.liveProcessInventory,
        timestamp: {
            ISO8601DateFormatter().string(from: Date())
        },
        operationID: {
            UUID().uuidString.lowercased()
        }
    )

    private static func liveProcessInventory() throws -> [DaemonProcessIdentity] {
        var processIDs = [pid_t](repeating: 0, count: 16_384)
        let count = proc_listallpids(
            &processIDs,
            Int32(processIDs.count * MemoryLayout<pid_t>.size)
        )
        guard count >= 0, count < processIDs.count else {
            throw DaemonLifecycleError.processInventoryUnavailable
        }
        return processIDs.prefix(Int(count)).compactMap { processID in
            guard processID > 0, processID != getpid() else { return nil }
            var path = [CChar](repeating: 0, count: 4_096)
            let length = proc_pidpath(processID, &path, UInt32(path.count))
            let executable: String
            if length > 0 {
                executable = String(
                    decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
            } else if let fallback = procArgumentsExecutablePath(processID: processID) {
                executable = fallback
            } else {
                return nil
            }
            return DaemonProcessIdentity(
                processID: Int32(processID),
                executablePath: canonicalProcessExecutablePath(executable)
            )
        }
    }

    package static func canonicalProcessExecutablePath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
            canonical,
            role: "process executable path"
        )) == canonical else {
            return path
        }
        return canonical
    }

    package static func launchdDisabledState(
        label: String,
        output: String
    ) throws -> Bool? {
        let prefixes = [
            "\"\(label)\" => ",
            "\(label) => ",
            "\"\(label)\" = ",
            "\(label) = "
        ]
        var states: [Bool] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else {
                continue
            }
            switch String(line.dropFirst(prefix.count)) {
            case "disabled", "true":
                states.append(true)
            case "enabled", "false":
                states.append(false)
            default:
                throw DaemonLifecycleError.verificationFailed(
                    "launchctl print-disabled reported an unknown managed state"
                )
            }
        }
        guard states.count <= 1 else {
            throw DaemonLifecycleError.verificationFailed(
                "launchctl print-disabled reported duplicate managed states"
            )
        }
        return states.first
    }

    private static func procArgumentsExecutablePath(processID: pid_t) -> String? {
        var managementInformationBase = [CTL_KERN, KERN_PROCARGS2, processID]
        var size = 0
        guard sysctl(
            &managementInformationBase,
            u_int(managementInformationBase.count),
            nil,
            &size,
            nil,
            0
        ) == 0,
        size > MemoryLayout<Int32>.size,
        size <= 1_048_576 else {
            return nil
        }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { buffer in
            sysctl(
                &managementInformationBase,
                u_int(managementInformationBase.count),
                buffer.baseAddress,
                &size,
                nil,
                0
            )
        }
        guard result == 0, size <= data.count else { return nil }
        return processExecutablePath(
            fromProcArguments: data.prefix(size)
        )
    }

    package static func processExecutablePath(
        fromProcArguments data: Data
    ) -> String? {
        guard data.count > MemoryLayout<Int32>.size else { return nil }
        let bytes = Array(data.dropFirst(MemoryLayout<Int32>.size))
        guard let terminator = bytes.firstIndex(of: 0), terminator > 0 else {
            return nil
        }
        let pathBytes = bytes[..<terminator]
        guard pathBytes.count < Int(PATH_MAX),
              pathBytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) else {
            return nil
        }
        let path = String(decoding: pathBytes, as: UTF8.self)
        return (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
            path,
            role: "process executable argument"
        )) == path ? path : nil
    }
}

public enum DaemonLifecycleError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidRequest(String)
    case unsafePath(String)
    case conflict(String)
    case externalServiceConflict(String)
    case unmanagedDaemonProcess(String)
    case commandFailed(String, Int32)
    case processInventoryUnavailable
    case notInstalled
    case rollbackUnavailable
    case recoveryRequired
    case verificationFailed(String)
    case cancelled

    public var description: String {
        switch self {
        case .invalidRequest(let message): "Invalid daemon lifecycle request: \(message)"
        case .unsafePath(let path): "Daemon lifecycle path failed secure validation: \(path)"
        case .conflict(let message): "Daemon lifecycle ownership conflict: \(message)"
        case .externalServiceConflict(let target):
            "External Hostwright service is loaded and will not be adopted: \(target)"
        case .unmanagedDaemonProcess(let path):
            "Unmanaged hostwrightd process is running and will not be adopted: \(path)"
        case .commandFailed(let command, let status):
            "Daemon lifecycle command failed (\(status)): \(command)"
        case .processInventoryUnavailable: "Daemon process inventory is unavailable."
        case .notInstalled: "The managed Hostwright LaunchAgent is not installed."
        case .rollbackUnavailable: "No verified prior LaunchAgent generation is available."
        case .recoveryRequired: "A pending daemon lifecycle journal requires repair."
        case .verificationFailed(let message): "Daemon lifecycle verification failed: \(message)"
        case .cancelled: "Daemon lifecycle operation was cancelled with durable recovery intent."
        }
    }
}

private func isCanonicalLifecycleUUID(_ value: String) -> Bool {
    guard let identifier = UUID(uuidString: value) else { return false }
    return identifier.uuidString.lowercased() == value
}

private struct DaemonLifecycleOwnershipRecord: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let installationID: String
    let generation: Int
    let label: String
    let domain: String
    let propertyListPath: String
    let propertyListSHA256: String
    let daemonExecutablePath: String
    let configPath: String
    let desiredLoaded: Bool
    let disabled: Bool
    let updatedAt: String

    init(
        installationID: String,
        generation: Int,
        layout: DaemonLifecycleLayout,
        propertyListSHA256: String,
        daemonExecutablePath: String,
        configPath: String,
        desiredLoaded: Bool,
        disabled: Bool,
        updatedAt: String
    ) {
        self.schemaVersion = 1
        self.kind = "daemonLifecycleOwnership"
        self.installationID = installationID
        self.generation = generation
        self.label = layout.label
        self.domain = layout.domain
        self.propertyListPath = layout.propertyListPath
        self.propertyListSHA256 = propertyListSHA256
        self.daemonExecutablePath = daemonExecutablePath
        self.configPath = configPath
        self.desiredLoaded = desiredLoaded
        self.disabled = disabled
        self.updatedAt = updatedAt
    }

    func validate(layout: DaemonLifecycleLayout) throws {
        guard schemaVersion == 1,
              kind == "daemonLifecycleOwnership",
              isCanonicalLifecycleUUID(installationID),
              generation > 0,
              label == layout.label,
              domain == layout.domain,
              propertyListPath == layout.propertyListPath,
              propertyListSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              daemonExecutablePath == (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
                daemonExecutablePath,
                role: "managed daemon executable"
              )),
              configPath == (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
                configPath,
                role: "managed daemon configuration"
              )),
              ISO8601DateFormatter().date(from: updatedAt) != nil,
              !(disabled && desiredLoaded) else {
            throw DaemonLifecycleError.conflict("the ownership record is invalid")
        }
    }

    func replacing(
        desiredLoaded: Bool? = nil,
        disabled: Bool? = nil,
        updatedAt: String
    ) -> Self {
        Self(
            installationID: installationID,
            generation: generation,
            layout: DaemonLifecycleLayout(
                homeDirectory: URL(fileURLWithPath: propertyListPath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent().path,
                userID: UInt32(domain.split(separator: "/").last.flatMap { UInt32($0) } ?? geteuid())
            ),
            propertyListSHA256: propertyListSHA256,
            daemonExecutablePath: daemonExecutablePath,
            configPath: configPath,
            desiredLoaded: desiredLoaded ?? self.desiredLoaded,
            disabled: disabled ?? self.disabled,
            updatedAt: updatedAt
        )
    }
}

private struct DaemonLifecycleRollbackRecord: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let prior: DaemonLifecycleOwnershipRecord
    let propertyListData: Data

    init(prior: DaemonLifecycleOwnershipRecord, propertyListData: Data) {
        self.schemaVersion = 1
        self.kind = "daemonLifecycleRollback"
        self.prior = prior
        self.propertyListData = propertyListData
    }
}

private struct DaemonLifecycleJournal: Codable, Equatable {
    let schemaVersion: Int
    let kind: String
    let operationID: String
    let operation: DaemonLifecycleOperation
    let checkpoint: DaemonLifecycleCheckpoint
    let before: DaemonLifecycleOwnershipRecord?
    let target: DaemonLifecycleOwnershipRecord?
    let beforePropertyListData: Data?
    let targetPropertyListData: Data?
    let startedAt: String

    init(
        operationID: String,
        operation: DaemonLifecycleOperation,
        checkpoint: DaemonLifecycleCheckpoint,
        before: DaemonLifecycleOwnershipRecord?,
        target: DaemonLifecycleOwnershipRecord?,
        beforePropertyListData: Data?,
        targetPropertyListData: Data?,
        startedAt: String
    ) {
        self.schemaVersion = 1
        self.kind = "daemonLifecycleJournal"
        self.operationID = operationID
        self.operation = operation
        self.checkpoint = checkpoint
        self.before = before
        self.target = target
        self.beforePropertyListData = beforePropertyListData
        self.targetPropertyListData = targetPropertyListData
        self.startedAt = startedAt
    }

    func replacing(checkpoint: DaemonLifecycleCheckpoint) -> Self {
        Self(
            operationID: operationID,
            operation: operation,
            checkpoint: checkpoint,
            before: before,
            target: target,
            beforePropertyListData: beforePropertyListData,
            targetPropertyListData: targetPropertyListData,
            startedAt: startedAt
        )
    }
}

private struct DaemonLaunchdObservation {
    let propertyListPath: String
    let programPath: String
    let state: String
    let processID: Int32?

    var isRunning: Bool { state == "running" }
}

private enum DaemonLifecycleRecordShape {
    case ownership
    case rollback
    case journal

    private static let ownershipKeys: Set<String> = [
        "schemaVersion",
        "kind",
        "installationID",
        "generation",
        "label",
        "domain",
        "propertyListPath",
        "propertyListSHA256",
        "daemonExecutablePath",
        "configPath",
        "desiredLoaded",
        "disabled",
        "updatedAt"
    ]

    func validate(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return false }
        switch self {
        case .ownership:
            return Self.isOwnership(dictionary)
        case .rollback:
            return Set(dictionary.keys) == [
                "schemaVersion", "kind", "prior", "propertyListData"
            ] && Self.isOwnership(dictionary["prior"] as? [String: Any])
        case .journal:
            let keys = Set(dictionary.keys)
            let allowedKeys: Set<String> = [
                "schemaVersion",
                "kind",
                "operationID",
                "operation",
                "checkpoint",
                "before",
                "target",
                "beforePropertyListData",
                "targetPropertyListData",
                "startedAt"
            ]
            let requiredKeys: Set<String> = [
                "schemaVersion",
                "kind",
                "operationID",
                "operation",
                "checkpoint",
                "startedAt"
            ]
            guard keys.isSubset(of: allowedKeys),
                  requiredKeys.isSubset(of: keys) else { return false }
            return Self.isOptionalOwnership(dictionary["before"])
                && Self.isOptionalOwnership(dictionary["target"])
        }
    }

    private static func isOptionalOwnership(_ value: Any?) -> Bool {
        value == nil || value is NSNull || isOwnership(value as? [String: Any])
    }

    private static func isOwnership(_ dictionary: [String: Any]?) -> Bool {
        guard let dictionary else { return false }
        return Set(dictionary.keys) == ownershipKeys
    }
}

public struct DaemonLifecycleController: @unchecked Sendable {
    private let layout: DaemonLifecycleLayout
    private let dependencies: DaemonLifecycleDependencies
    private let cancellation: SecureSubprocessCancellation
    private let cancelAfter: DaemonLifecycleCheckpoint?

    public init(
        layout: DaemonLifecycleLayout = .currentUser,
        dependencies: DaemonLifecycleDependencies = .live,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) {
        self.layout = layout
        self.dependencies = dependencies
        self.cancellation = cancellation
        self.cancelAfter = nil
    }

    init(
        layout: DaemonLifecycleLayout,
        dependencies: DaemonLifecycleDependencies,
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation(),
        cancelAfter: DaemonLifecycleCheckpoint?
    ) {
        self.layout = layout
        self.dependencies = dependencies
        self.cancellation = cancellation
        self.cancelAfter = cancelAfter
    }

    public func status() throws -> DaemonLifecycleStatus {
        try validateLayout()
        if let journal = try readJournal() {
            let record = journal.target ?? journal.before
            return makeStatus(
                record: record,
                readiness: .recoveryRequired,
                processID: nil,
                pendingOperation: journal.operation,
                reasonCode: .recoveryRequired
            )
        }
        guard let record = try readOwnershipRecord() else {
            if secureEntryExists(layout.propertyListPath) {
                throw DaemonLifecycleError.conflict(
                    "the managed plist path exists without an ownership record"
                )
            }
            if try launchdObservation(target: layout.serviceTarget) != nil {
                throw DaemonLifecycleError.conflict(
                    "the managed launchd label is loaded without an ownership record"
                )
            }
            if try launchdObservation(target: layout.homebrewServiceTarget) != nil {
                throw DaemonLifecycleError.externalServiceConflict(
                    layout.homebrewServiceTarget
                )
            }
            if try isDisabled() {
                throw DaemonLifecycleError.conflict(
                    "the managed launchd label has an unowned persistent disabled override"
                )
            }
            _ = try validateProcessInventory(
                managedExecutablePath: nil,
                expectsRunning: false
            )
            return makeStatus(
                record: nil,
                readiness: .notInstalled,
                processID: nil,
                pendingOperation: nil,
                reasonCode: .notInstalled
            )
        }
        try record.validate(layout: layout)
        try requireNoLoadedHomebrewService()
        let propertyListData = try readSecureFile(
            layout.propertyListPath,
            maximumBytes: 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        )
        guard let propertyListData else {
            return makeStatus(
                record: record,
                readiness: .recoveryRequired,
                processID: nil,
                pendingOperation: .repair,
                reasonCode: .recoveryRequired
            )
        }
        guard sha256(propertyListData) == record.propertyListSHA256 else {
            throw DaemonLifecycleError.conflict("the managed plist bytes changed")
        }
        try validatePropertyList(propertyListData, record: record)
        let disabled = try isDisabled()
        guard disabled == record.disabled else {
            return makeStatus(
                record: record,
                readiness: .recoveryRequired,
                processID: nil,
                pendingOperation: .repair,
                reasonCode: .recoveryRequired
            )
        }
        let observation = try launchdObservation(target: layout.serviceTarget)
        if let observation {
            guard observation.propertyListPath == layout.propertyListPath,
                  observation.programPath == record.daemonExecutablePath else {
                throw DaemonLifecycleError.conflict(
                    "the loaded launchd service does not match exact ownership"
                )
            }
        }
        let processID = try validateProcessInventory(
            managedExecutablePath: record.daemonExecutablePath,
            expectsRunning: observation?.isRunning == true
        )
        try validateLaunchdProcessIdentity(
            observation: observation,
            inventoryProcessID: processID
        )
        let readiness: DaemonLifecycleReadiness
        if disabled {
            readiness = .disabled
        } else if observation?.isRunning == true {
            readiness = .running
        } else {
            readiness = .stopped
        }
        let reasonCode: DaemonLifecycleReasonCode = switch readiness {
        case .running: .started
        case .disabled: .disabled
        case .stopped: .stopped
        case .notInstalled: .notInstalled
        case .recoveryRequired: .recoveryRequired
        }
        return makeStatus(
            record: record,
            readiness: readiness,
            processID: processID,
            pendingOperation: nil,
            reasonCode: reasonCode
        )
    }

    public func perform(
        _ operation: DaemonLifecycleOperation,
        daemonExecutablePath: String? = nil,
        configPath: String? = nil
    ) throws -> DaemonLifecycleResult {
        try requireNotCancelled()
        if operation != .install,
           operation != .upgrade,
           (daemonExecutablePath != nil || configPath != nil) {
            throw DaemonLifecycleError.invalidRequest(
                "\(operation.rawValue) does not accept executable or configuration overrides"
            )
        }
        switch operation {
        case .status:
            let current = try status()
            return DaemonLifecycleResult(
                operation: operation,
                changed: false,
                reasonCode: current.reasonCode,
                status: current
            )
        case .validate:
            let current = try status()
            guard current.readiness != .notInstalled else {
                throw DaemonLifecycleError.notInstalled
            }
            guard current.readiness != .recoveryRequired else {
                throw DaemonLifecycleError.recoveryRequired
            }
            try revalidateTargetInputs(try requireCurrentRecord())
            return DaemonLifecycleResult(
                operation: operation,
                changed: false,
                reasonCode: .validated,
                status: current
            )
        case .install:
            return try withMutationLock {
                try install(
                    daemonExecutablePath: requireValue(
                        daemonExecutablePath,
                        role: "install daemon executable"
                    ),
                    configPath: requireValue(configPath, role: "install configuration")
                )
            }
        case .upgrade:
            return try withMutationLock {
                try upgrade(
                    daemonExecutablePath: requireValue(
                        daemonExecutablePath,
                        role: "upgrade daemon executable"
                    ),
                    configPath: requireValue(configPath, role: "upgrade configuration")
                )
            }
        case .rollback:
            return try withMutationLock { try rollback() }
        case .repair:
            return try withMutationLock { try repair() }
        case .uninstall:
            return try withMutationLock {
                try transition(
                    operation: .uninstall,
                    target: nil,
                    reasonCode: .uninstalled
                )
            }
        case .bootstrap, .start, .kickstart, .stop, .disable:
            return try withMutationLock {
                let current = try requireCurrentRecord()
                let timestamp = dependencies.timestamp()
                let target: DaemonLifecycleOwnershipRecord
                let reason: DaemonLifecycleReasonCode
                switch operation {
                case .bootstrap:
                    target = current.replacing(
                        desiredLoaded: true,
                        disabled: false,
                        updatedAt: timestamp
                    )
                    reason = .bootstrapped
                case .start:
                    target = current.replacing(
                        desiredLoaded: true,
                        disabled: false,
                        updatedAt: timestamp
                    )
                    reason = .started
                case .kickstart:
                    target = current.replacing(
                        desiredLoaded: true,
                        disabled: false,
                        updatedAt: timestamp
                    )
                    reason = .kickstarted
                case .stop:
                    target = current.replacing(
                        desiredLoaded: false,
                        updatedAt: timestamp
                    )
                    reason = .stopped
                case .disable:
                    target = current.replacing(
                        desiredLoaded: false,
                        disabled: true,
                        updatedAt: timestamp
                    )
                    reason = .disabled
                default:
                    fatalError("unreachable lifecycle transition")
                }
                return try transition(
                    operation: operation,
                    target: target,
                    reasonCode: reason
                )
            }
        }
    }

    private func withMutationLock<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        try validateLayout()
        try validateDirectory(layout.homeDirectory, requirePrivate: true)
        let descriptor = open(
            layout.homeDirectory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DaemonLifecycleError.unsafePath(layout.homeDirectory)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw DaemonLifecycleError.conflict(
                    "another daemon lifecycle controller is active"
                )
            }
            throw DaemonLifecycleError.unsafePath(layout.homeDirectory)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func install(
        daemonExecutablePath: String,
        configPath: String
    ) throws -> DaemonLifecycleResult {
        try validateLayout()
        guard try readJournal() == nil else { throw DaemonLifecycleError.recoveryRequired }
        guard try readOwnershipRecord() == nil,
              !secureEntryExists(layout.propertyListPath),
              try launchdObservation(target: layout.serviceTarget) == nil,
              try !isDisabled() else {
            throw DaemonLifecycleError.conflict("the managed LaunchAgent is already present")
        }
        try ensureNoExternalServiceOrDaemon(managedExecutablePath: nil)
        let (specification, propertyListData) = try validatedSpecification(
            daemonExecutablePath: daemonExecutablePath,
            configPath: configPath
        )
        let identifier = dependencies.operationID().lowercased()
        guard isCanonicalLifecycleUUID(identifier) else {
            throw DaemonLifecycleError.invalidRequest("operation identifier is invalid")
        }
        let target = DaemonLifecycleOwnershipRecord(
            installationID: identifier,
            generation: 1,
            layout: specification.layout,
            propertyListSHA256: sha256(propertyListData),
            daemonExecutablePath: specification.daemonExecutablePath,
            configPath: specification.configPath,
            desiredLoaded: true,
            disabled: false,
            updatedAt: dependencies.timestamp()
        )
        return try transition(
            operation: .install,
            target: target,
            targetPropertyListData: propertyListData,
            reasonCode: .installed
        )
    }

    private func upgrade(
        daemonExecutablePath: String,
        configPath: String
    ) throws -> DaemonLifecycleResult {
        let current = try requireCurrentRecord()
        try ensureNoExternalServiceOrDaemon(
            managedExecutablePath: current.daemonExecutablePath
        )
        let (specification, propertyListData) = try validatedSpecification(
            daemonExecutablePath: daemonExecutablePath,
            configPath: configPath
        )
        guard specification.daemonExecutablePath != current.daemonExecutablePath
                || specification.configPath != current.configPath else {
            throw DaemonLifecycleError.invalidRequest(
                "upgrade requires a changed executable or configuration path"
            )
        }
        let target = DaemonLifecycleOwnershipRecord(
            installationID: current.installationID,
            generation: current.generation + 1,
            layout: layout,
            propertyListSHA256: sha256(propertyListData),
            daemonExecutablePath: specification.daemonExecutablePath,
            configPath: specification.configPath,
            desiredLoaded: current.desiredLoaded,
            disabled: current.disabled,
            updatedAt: dependencies.timestamp()
        )
        let priorData = try requireCurrentPropertyList(current)
        let journal = try beginJournal(
            operation: .upgrade,
            before: current,
            target: target,
            beforePropertyListData: priorData,
            targetPropertyListData: propertyListData
        )
        try writeCodable(
            DaemonLifecycleRollbackRecord(prior: current, propertyListData: priorData),
            to: layout.rollbackPath
        )
        let advanced = try advance(journal, to: .rollbackPublished)
        return try execute(
            advanced,
            reasonCode: .upgraded,
            recovering: false
        )
    }

    private func rollback() throws -> DaemonLifecycleResult {
        let current = try requireCurrentRecord()
        guard let rollback: DaemonLifecycleRollbackRecord = try readCodable(
            DaemonLifecycleRollbackRecord.self,
            from: layout.rollbackPath,
            shape: .rollback
        ) else {
            throw DaemonLifecycleError.rollbackUnavailable
        }
        guard rollback.schemaVersion == 1,
              rollback.kind == "daemonLifecycleRollback" else {
            throw DaemonLifecycleError.conflict("the rollback record is invalid")
        }
        try rollback.prior.validate(layout: layout)
        guard sha256(rollback.propertyListData) == rollback.prior.propertyListSHA256,
              rollback.prior.installationID == current.installationID,
              rollback.prior.generation == current.generation - 1 else {
            throw DaemonLifecycleError.conflict("the rollback generation is not the exact prior generation")
        }
        try validatePropertyList(rollback.propertyListData, record: rollback.prior)
        let result = try transition(
            operation: .rollback,
            target: rollback.prior,
            targetPropertyListData: rollback.propertyListData,
            reasonCode: .rolledBack
        )
        try removeSecureFileIfPresent(layout.rollbackPath, expectedSHA256: nil)
        return result
    }

    private func repair() throws -> DaemonLifecycleResult {
        if let journal = try readJournal() {
            try ensureExactUpgradeRollbackRecord(journal)
            return try execute(journal, reasonCode: .recovered, recovering: true)
        }
        let current = try requireCurrentRecord(allowMissingPropertyList: true)
        let propertyListData = try DaemonLaunchAgentSpecification(
            layout: layout,
            daemonExecutablePath: current.daemonExecutablePath,
            configPath: current.configPath
        ).propertyListData()
        guard sha256(propertyListData) == current.propertyListSHA256 else {
            throw DaemonLifecycleError.conflict(
                "the ownership record cannot reproduce the exact managed plist"
            )
        }
        let existingData = secureEntryExists(layout.propertyListPath)
            ? try requireCurrentPropertyList(current)
            : nil
        let journal = try beginJournal(
            operation: .repair,
            before: current,
            target: current,
            beforePropertyListData: existingData,
            targetPropertyListData: propertyListData
        )
        return try execute(
            journal,
            reasonCode: .repaired,
            recovering: true
        )
    }

    private func transition(
        operation: DaemonLifecycleOperation,
        target: DaemonLifecycleOwnershipRecord?,
        targetPropertyListData: Data? = nil,
        reasonCode: DaemonLifecycleReasonCode
    ) throws -> DaemonLifecycleResult {
        guard try readJournal() == nil else { throw DaemonLifecycleError.recoveryRequired }
        let before = try readOwnershipRecord()
        if operation != .install {
            guard before != nil else { throw DaemonLifecycleError.notInstalled }
        }
        let beforeData = try before.map(requireCurrentPropertyList)
        let targetData: Data?
        if let targetPropertyListData {
            targetData = targetPropertyListData
        } else if target != nil {
            targetData = beforeData
        } else {
            targetData = nil
        }
        let journal = try beginJournal(
            operation: operation,
            before: before,
            target: target,
            beforePropertyListData: beforeData,
            targetPropertyListData: targetData
        )
        return try execute(journal, reasonCode: reasonCode, recovering: false)
    }

    private func beginJournal(
        operation: DaemonLifecycleOperation,
        before: DaemonLifecycleOwnershipRecord?,
        target: DaemonLifecycleOwnershipRecord?,
        beforePropertyListData: Data?,
        targetPropertyListData: Data?
    ) throws -> DaemonLifecycleJournal {
        try ensureLifecycleDirectories()
        let operationID = dependencies.operationID().lowercased()
        guard isCanonicalLifecycleUUID(operationID) else {
            throw DaemonLifecycleError.invalidRequest("operation identifier is invalid")
        }
        let journal = DaemonLifecycleJournal(
            operationID: operationID,
            operation: operation,
            checkpoint: .intentRecorded,
            before: before,
            target: target,
            beforePropertyListData: beforePropertyListData,
            targetPropertyListData: targetPropertyListData,
            startedAt: dependencies.timestamp()
        )
        try writeCodableNew(journal, to: layout.journalPath)
        try triggerCancellationIfRequested(after: .intentRecorded)
        return journal
    }

    private func execute(
        _ initialJournal: DaemonLifecycleJournal,
        reasonCode: DaemonLifecycleReasonCode,
        recovering: Bool
    ) throws -> DaemonLifecycleResult {
        var journal = initialJournal
        try requireNotCancelled()
        let currentObservation = try launchdObservation(target: layout.serviceTarget)
        var bootedOutExecutablePath: String?
        try requireNoLoadedHomebrewService()
        if let currentObservation {
            let activeRecord = try exactOwnedRecord(
                for: currentObservation,
                journal: journal
            )
            let processID = try validateProcessInventory(
                managedExecutablePath: activeRecord.daemonExecutablePath,
                expectsRunning: currentObservation.isRunning
            )
            try validateLaunchdProcessIdentity(
                observation: currentObservation,
                inventoryProcessID: processID
            )
            bootedOutExecutablePath = activeRecord.daemonExecutablePath
            try runLaunchctl(["bootout", layout.serviceTarget])
        } else {
            _ = try validateProcessInventory(
                managedExecutablePath: nil,
                expectsRunning: false
            )
        }
        try waitForServiceAbsence(
            managedExecutablePath: bootedOutExecutablePath
        )
        journal = try advance(journal, to: .serviceStopped)

        if let target = journal.target,
           let targetData = journal.targetPropertyListData {
            try target.validate(layout: layout)
            try validatePropertyList(targetData, record: target)
            try ensureLifecycleDirectories()
            try prepareLogFiles(
                allowExisting: journal.before != nil
                    || (recovering
                        && initialJournal.checkpoint.provesManagedLogsWerePrepared)
            )
            try publishPropertyList(
                targetData,
                before: journal.before,
                target: target,
                recovering: recovering
            )
            journal = try advance(journal, to: .propertyListPublished)
            if target.disabled {
                try runLaunchctl(["disable", layout.serviceTarget])
            } else {
                try runLaunchctl(["enable", layout.serviceTarget])
            }
            journal = try advance(journal, to: .disabledStatePublished)
            if target.desiredLoaded {
                try requireNoLoadedHomebrewService()
                try revalidateTargetInputs(target)
                guard try launchdObservation(target: layout.serviceTarget) == nil else {
                    throw DaemonLifecycleError.conflict(
                        "the managed launchd label was loaded before bootstrap"
                    )
                }
                _ = try validateProcessInventory(
                    managedExecutablePath: nil,
                    expectsRunning: false
                )
                try runLaunchctl(["bootstrap", layout.domain, layout.propertyListPath])
                try runLaunchctl(["kickstart", "-k", layout.serviceTarget])
            }
            journal = try advance(journal, to: .serviceStarted)
            let verifiedProcessID = try waitForVerifiedTarget(target)
            journal = try advance(journal, to: .verified)
            try writeCodable(target, to: layout.statusPath)
            journal = try advance(journal, to: .statusPublished)
            try removeSecureFileIfPresent(layout.journalPath, expectedSHA256: nil)
            let current = makeStatus(
                record: target,
                readiness: target.disabled
                    ? .disabled
                    : (target.desiredLoaded ? .running : .stopped),
                processID: verifiedProcessID,
                pendingOperation: nil,
                reasonCode: reasonCode
            )
            return DaemonLifecycleResult(
                operation: initialJournal.operation,
                changed: true,
                reasonCode: reasonCode,
                status: current
            )
        }

        guard journal.operation == .uninstall, let before = journal.before else {
            throw DaemonLifecycleError.verificationFailed(
                "the lifecycle journal has no exact target"
            )
        }
        try runLaunchctl(["enable", layout.serviceTarget])
        journal = try advance(journal, to: .disabledStatePublished)
        try removeSecureFileIfPresent(
            layout.propertyListPath,
            expectedSHA256: before.propertyListSHA256
        )
        journal = try advance(journal, to: .propertyListPublished)
        try removeSecureFileIfPresent(layout.statusPath, expectedSHA256: nil)
        try removeSecureFileIfPresent(layout.rollbackPath, expectedSHA256: nil)
        try removeSecureFileIfPresent(layout.standardOutputPath, expectedSHA256: nil)
        try removeSecureFileIfPresent(layout.standardErrorPath, expectedSHA256: nil)
        journal = try advance(journal, to: .verified)
        try removeSecureFileIfPresent(layout.journalPath, expectedSHA256: nil)
        try removeDirectoryIfEmpty(layout.logDirectory)
        try removeDirectoryIfEmpty(layout.lifecycleDirectory)
        return DaemonLifecycleResult(
            operation: .uninstall,
            changed: true,
            reasonCode: .uninstalled,
            status: makeStatus(
                record: nil,
                readiness: .notInstalled,
                processID: nil,
                pendingOperation: nil,
                reasonCode: .uninstalled
            )
        )
    }

    private func verifyTarget(
        _ target: DaemonLifecycleOwnershipRecord
    ) throws -> Int32? {
        try requireNoLoadedHomebrewService()
        let propertyListData = try readSecureFile(
            layout.propertyListPath,
            maximumBytes: 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        )
        guard let propertyListData,
              sha256(propertyListData) == target.propertyListSHA256,
              try isDisabled() == target.disabled else {
            throw DaemonLifecycleError.verificationFailed(
                "plist or disabled state does not match durable intent"
            )
        }
        try validatePropertyList(propertyListData, record: target)
        let observation = try launchdObservation(target: layout.serviceTarget)
        if target.desiredLoaded {
            guard let observation,
                  observation.isRunning,
                  observation.propertyListPath == layout.propertyListPath,
                  observation.programPath == target.daemonExecutablePath else {
                throw DaemonLifecycleError.verificationFailed(
                    "launchd did not report the exact managed service running"
                )
            }
            let processID = try validateProcessInventory(
                managedExecutablePath: target.daemonExecutablePath,
                expectsRunning: true
            )
            try validateLaunchdProcessIdentity(
                observation: observation,
                inventoryProcessID: processID
            )
            return processID
        } else {
            guard observation == nil else {
                throw DaemonLifecycleError.verificationFailed(
                    "launchd still reports the managed service loaded"
                )
            }
            _ = try validateProcessInventory(
                managedExecutablePath: target.daemonExecutablePath,
                expectsRunning: false
            )
            return nil
        }
    }

    private func waitForVerifiedTarget(
        _ target: DaemonLifecycleOwnershipRecord
    ) throws -> Int32? {
        var lastVerificationError: DaemonLifecycleError?
        for attempt in 0..<100 {
            try requireNotCancelled()
            do {
                return try verifyTarget(target)
            } catch let error as DaemonLifecycleError {
                guard case .verificationFailed = error else { throw error }
                lastVerificationError = error
            }
            if attempt < 99 { usleep(50_000) }
        }
        throw lastVerificationError ?? .verificationFailed(
            "the managed service did not converge within five seconds"
        )
    }

    private func waitForServiceAbsence(
        managedExecutablePath: String?
    ) throws {
        var lastVerificationError: DaemonLifecycleError?
        for attempt in 0..<100 {
            try requireNotCancelled()
            do {
                guard try launchdObservation(target: layout.serviceTarget) == nil else {
                    throw DaemonLifecycleError.verificationFailed(
                        "launchd still reports the managed service after bootout"
                    )
                }
                _ = try validateProcessInventory(
                    managedExecutablePath: managedExecutablePath,
                    expectsRunning: false
                )
                return
            } catch let error as DaemonLifecycleError {
                guard case .verificationFailed = error else { throw error }
                lastVerificationError = error
            }
            if attempt < 99 { usleep(50_000) }
        }
        throw lastVerificationError ?? .verificationFailed(
            "the managed service did not stop within five seconds"
        )
    }

    private func ensureExactUpgradeRollbackRecord(
        _ journal: DaemonLifecycleJournal
    ) throws {
        guard journal.operation == .upgrade else { return }
        guard let before = journal.before,
              let beforeData = journal.beforePropertyListData,
              sha256(beforeData) == before.propertyListSHA256 else {
            throw DaemonLifecycleError.conflict(
                "the upgrade journal has no exact rollback generation"
            )
        }
        let expected = DaemonLifecycleRollbackRecord(
            prior: before,
            propertyListData: beforeData
        )
        if secureEntryExists(layout.rollbackPath) {
            guard let existing: DaemonLifecycleRollbackRecord = try readCodable(
                DaemonLifecycleRollbackRecord.self,
                from: layout.rollbackPath,
                shape: .rollback
            ), existing == expected else {
                throw DaemonLifecycleError.conflict(
                    "the pending upgrade rollback record changed"
                )
            }
        } else {
            try writeCodable(expected, to: layout.rollbackPath)
        }
    }

    private func requireCurrentRecord(
        allowMissingPropertyList: Bool = false
    ) throws -> DaemonLifecycleOwnershipRecord {
        guard try readJournal() == nil else { throw DaemonLifecycleError.recoveryRequired }
        guard let record = try readOwnershipRecord() else {
            throw DaemonLifecycleError.notInstalled
        }
        try record.validate(layout: layout)
        if !allowMissingPropertyList {
            _ = try requireCurrentPropertyList(record)
        } else if secureEntryExists(layout.propertyListPath) {
            _ = try requireCurrentPropertyList(record)
        }
        return record
    }

    private func requireCurrentPropertyList(
        _ record: DaemonLifecycleOwnershipRecord
    ) throws -> Data {
        guard let data = try readSecureFile(
            layout.propertyListPath,
            maximumBytes: 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        ), sha256(data) == record.propertyListSHA256 else {
            throw DaemonLifecycleError.conflict("the managed plist is absent or changed")
        }
        try validatePropertyList(data, record: record)
        return data
    }

    private func validatedSpecification(
        daemonExecutablePath: String,
        configPath: String
    ) throws -> (DaemonLaunchAgentSpecification, Data) {
        let requested: DaemonLaunchAgentSpecification
        do {
            requested = try DaemonLaunchAgentSpecification(
                layout: layout,
                daemonExecutablePath: daemonExecutablePath,
                configPath: configPath
            )
        } catch {
            throw DaemonLifecycleError.invalidRequest(String(describing: error))
        }
        guard URL(fileURLWithPath: requested.daemonExecutablePath).lastPathComponent
            == HostwrightIdentity.daemonName else {
            throw DaemonLifecycleError.invalidRequest(
                "the managed executable must be named hostwrightd"
            )
        }
        do {
            let executableIdentity = try SecureExecutableResolver.verify(
                path: requested.daemonExecutablePath,
                ownershipPolicy: .rootOrCurrentUser
            )
            guard try readSecureFile(
                requested.configPath,
                maximumBytes: 16 * 1_048_576,
                allowRootOwner: true,
                requireMode: nil
            ) != nil else {
                throw DaemonLifecycleError.unsafePath(requested.configPath)
            }
            let canonicalConfigPath = try canonicalExistingPath(requested.configPath)
            let specification = try DaemonLaunchAgentSpecification(
                layout: layout,
                daemonExecutablePath: executableIdentity.path,
                configPath: canonicalConfigPath
            )
            let propertyListData = try specification.propertyListData()
            return (specification, propertyListData)
        } catch let error as DaemonLifecycleError {
            throw error
        } catch {
            throw DaemonLifecycleError.unsafePath(
                "\(requested.daemonExecutablePath) (\(String(describing: error)))"
            )
        }
    }

    private func canonicalExistingPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
            canonical,
            role: "canonical daemon lifecycle path"
        )) == canonical else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        return canonical
    }

    private func validatePropertyList(
        _ data: Data,
        record: DaemonLifecycleOwnershipRecord
    ) throws {
        guard data.count <= 1_048_576,
              let object = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              Set(object.keys) == Set([
                "Label",
                "ProgramArguments",
                "RunAtLoad",
                "KeepAlive",
                "ThrottleInterval",
                "ProcessType",
                "Umask",
                "StandardOutPath",
                "StandardErrorPath"
              ]),
              object["Label"] as? String == layout.label,
              object["ProgramArguments"] as? [String] == [
                record.daemonExecutablePath,
                "--service",
                "--config",
                record.configPath
              ],
              object["RunAtLoad"] as? Bool == true,
              object["KeepAlive"] as? Bool == true,
              object["ThrottleInterval"] as? Int == 10,
              object["ProcessType"] as? String == "Background",
              object["Umask"] as? String == "0077",
              object["StandardOutPath"] as? String == layout.standardOutputPath,
              object["StandardErrorPath"] as? String == layout.standardErrorPath else {
            throw DaemonLifecycleError.conflict("the managed plist contract is invalid")
        }
    }

    private func ensureNoExternalServiceOrDaemon(
        managedExecutablePath: String?
    ) throws {
        try requireNoLoadedHomebrewService()
        _ = try validateProcessInventory(
            managedExecutablePath: managedExecutablePath,
            expectsRunning: managedExecutablePath != nil
                && (try launchdObservation(target: layout.serviceTarget)?.isRunning == true)
        )
    }

    private func requireNoLoadedHomebrewService() throws {
        if try launchdObservation(target: layout.homebrewServiceTarget) != nil {
            throw DaemonLifecycleError.externalServiceConflict(
                layout.homebrewServiceTarget
            )
        }
    }

    private func exactOwnedRecord(
        for observation: DaemonLaunchdObservation,
        journal: DaemonLifecycleJournal
    ) throws -> DaemonLifecycleOwnershipRecord {
        guard observation.propertyListPath == layout.propertyListPath else {
            throw DaemonLifecycleError.conflict(
                "the loaded launchd service has no exact managed plist"
            )
        }
        guard let propertyListData = try readSecureFile(
            layout.propertyListPath,
            maximumBytes: 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        ) else {
            guard journal.operation == .repair,
                  let before = journal.before,
                  journal.target == before,
                  observation.programPath == before.daemonExecutablePath,
                  let regenerated = journal.targetPropertyListData,
                  sha256(regenerated) == before.propertyListSHA256 else {
                throw DaemonLifecycleError.conflict(
                    "the loaded launchd service has no exact managed plist"
                )
            }
            try validatePropertyList(regenerated, record: before)
            return before
        }
        let digest = sha256(propertyListData)
        for candidate in [journal.target, journal.before].compactMap({ $0 }) {
            guard observation.programPath == candidate.daemonExecutablePath,
                  digest == candidate.propertyListSHA256 else { continue }
            try validatePropertyList(propertyListData, record: candidate)
            return candidate
        }
        throw DaemonLifecycleError.conflict(
            "the loaded launchd service no longer matches durable ownership"
        )
    }

    private func revalidateTargetInputs(
        _ target: DaemonLifecycleOwnershipRecord
    ) throws {
        do {
            let executable = try SecureExecutableResolver.verify(
                path: target.daemonExecutablePath,
                ownershipPolicy: .rootOrCurrentUser
            )
            guard executable.path == target.daemonExecutablePath,
                  try canonicalExistingPath(target.configPath) == target.configPath,
                  try readSecureFile(
                    target.configPath,
                    maximumBytes: 16 * 1_048_576,
                    allowRootOwner: true,
                    requireMode: nil
                  ) != nil else {
                throw DaemonLifecycleError.unsafePath(target.configPath)
            }
        } catch let error as DaemonLifecycleError {
            throw error
        } catch {
            throw DaemonLifecycleError.unsafePath(
                "daemon launch input changed before bootstrap (\(String(describing: error)))"
            )
        }
    }

    private func validateProcessInventory(
        managedExecutablePath: String?,
        expectsRunning: Bool
    ) throws -> Int32? {
        let identities = try dependencies.processInventory()
        let daemons = identities.filter {
            URL(fileURLWithPath: $0.executablePath).lastPathComponent
                == HostwrightIdentity.daemonName
        }
        let managed = daemons.filter { $0.executablePath == managedExecutablePath }
        if let unmanaged = daemons.first(where: { $0.executablePath != managedExecutablePath }) {
            throw DaemonLifecycleError.unmanagedDaemonProcess(unmanaged.executablePath)
        }
        if expectsRunning {
            guard managed.count == 1 else {
                throw DaemonLifecycleError.verificationFailed(
                    "exactly one managed hostwrightd process was required"
                )
            }
            return managed[0].processID
        }
        guard managed.isEmpty else {
            throw DaemonLifecycleError.verificationFailed(
                "the managed hostwrightd process remained after stop"
            )
        }
        return nil
    }

    private func validateLaunchdProcessIdentity(
        observation: DaemonLaunchdObservation?,
        inventoryProcessID: Int32?
    ) throws {
        guard let observation else {
            guard inventoryProcessID == nil else {
                throw DaemonLifecycleError.verificationFailed(
                    "a daemon process exists without the managed launchd service"
                )
            }
            return
        }
        if observation.isRunning {
            guard let launchdProcessID = observation.processID,
                  launchdProcessID > 0,
                  launchdProcessID == inventoryProcessID else {
                throw DaemonLifecycleError.verificationFailed(
                    "launchd and process inventory disagree on the managed daemon PID"
                )
            }
        } else {
            guard inventoryProcessID == nil else {
                throw DaemonLifecycleError.verificationFailed(
                    "launchd reports a stopped service with a managed daemon process"
                )
            }
        }
    }

    private func launchdObservation(
        target: String
    ) throws -> DaemonLaunchdObservation? {
        let result = try dependencies.runLaunchctl(
            ["print", target],
            cancellation
        )
        if result.exitStatus == 113 { return nil }
        guard result.exitStatus == 0 else {
            throw DaemonLifecycleError.commandFailed("launchctl print \(target)", result.exitStatus)
        }
        guard let path = launchdField("path", in: result.standardOutput),
              let program = launchdField("program", in: result.standardOutput),
              let state = launchdField("state", in: result.standardOutput) else {
            throw DaemonLifecycleError.verificationFailed(
                "launchctl print omitted required structured fields"
            )
        }
        let processID = launchdField("pid", in: result.standardOutput).flatMap(Int32.init)
        return DaemonLaunchdObservation(
            propertyListPath: path,
            programPath: program,
            state: state,
            processID: processID
        )
    }

    private func isDisabled() throws -> Bool {
        let result = try dependencies.runLaunchctl(
            ["print-disabled", layout.domain],
            cancellation
        )
        guard result.exitStatus == 0 else {
            throw DaemonLifecycleError.commandFailed(
                "launchctl print-disabled \(layout.domain)",
                result.exitStatus
            )
        }
        return try DaemonLifecycleDependencies.launchdDisabledState(
            label: layout.label,
            output: result.standardOutput
        ) ?? false
    }

    private func launchdField(_ key: String, in output: String) -> String? {
        let prefix = "\(key) = "
        return output.split(separator: "\n").compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
        }.first
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        try requireNotCancelled()
        let result = try dependencies.runLaunchctl(arguments, cancellation)
        guard result.exitStatus == 0 else {
            throw DaemonLifecycleError.commandFailed(
                "launchctl \(arguments.joined(separator: " "))",
                result.exitStatus
            )
        }
        try requireNotCancelled()
    }

    private func advance(
        _ journal: DaemonLifecycleJournal,
        to checkpoint: DaemonLifecycleCheckpoint
    ) throws -> DaemonLifecycleJournal {
        let advanced = journal.replacing(checkpoint: checkpoint)
        try writeCodable(advanced, to: layout.journalPath)
        try triggerCancellationIfRequested(after: checkpoint)
        return advanced
    }

    private func triggerCancellationIfRequested(
        after checkpoint: DaemonLifecycleCheckpoint
    ) throws {
        if cancelAfter == checkpoint {
            cancellation.cancel()
        }
        try requireNotCancelled()
    }

    private func requireNotCancelled() throws {
        guard !cancellation.isCancelled else {
            throw DaemonLifecycleError.cancelled
        }
    }

    private func readOwnershipRecord() throws -> DaemonLifecycleOwnershipRecord? {
        let record: DaemonLifecycleOwnershipRecord? = try readCodable(
            DaemonLifecycleOwnershipRecord.self,
            from: layout.statusPath,
            shape: .ownership
        )
        try record?.validate(layout: layout)
        return record
    }

    private func readJournal() throws -> DaemonLifecycleJournal? {
        guard let journal: DaemonLifecycleJournal = try readCodable(
            DaemonLifecycleJournal.self,
            from: layout.journalPath,
            shape: .journal
        ) else { return nil }
        guard journal.schemaVersion == 1,
              journal.kind == "daemonLifecycleJournal",
              isCanonicalLifecycleUUID(journal.operationID),
              ISO8601DateFormatter().date(from: journal.startedAt) != nil else {
            throw DaemonLifecycleError.conflict("the lifecycle journal is invalid")
        }
        try journal.before?.validate(layout: layout)
        try journal.target?.validate(layout: layout)
        try validateJournalSemantics(journal)
        return journal
    }

    private func validateJournalSemantics(
        _ journal: DaemonLifecycleJournal
    ) throws {
        let beforeDigestMatches = journal.beforePropertyListData.map(sha256)
            == journal.before?.propertyListSHA256
        let targetDigestMatches = journal.targetPropertyListData.map(sha256)
            == journal.target?.propertyListSHA256
        guard (journal.before == nil) == (journal.beforePropertyListData == nil)
                || (journal.operation == .repair
                    && journal.before != nil
                    && journal.beforePropertyListData == nil),
              (journal.target == nil) == (journal.targetPropertyListData == nil),
              journal.beforePropertyListData == nil || beforeDigestMatches,
              journal.targetPropertyListData == nil || targetDigestMatches else {
            throw DaemonLifecycleError.conflict(
                "the lifecycle journal record bytes do not match durable intent"
            )
        }
        if journal.checkpoint == .rollbackPublished,
           journal.operation != .upgrade {
            throw DaemonLifecycleError.conflict(
                "the lifecycle journal checkpoint is invalid for its operation"
            )
        }
        switch journal.operation {
        case .install:
            guard journal.before == nil,
                  journal.target?.generation == 1 else {
                throw DaemonLifecycleError.conflict(
                    "the install journal is not an initial generation"
                )
            }
        case .uninstall:
            guard journal.before != nil, journal.target == nil else {
                throw DaemonLifecycleError.conflict(
                    "the uninstall journal has an invalid target"
                )
            }
        case .upgrade:
            guard let before = journal.before,
                  let target = journal.target,
                  target.installationID == before.installationID,
                  target.generation == before.generation + 1 else {
                throw DaemonLifecycleError.conflict(
                    "the upgrade journal is not the exact next generation"
                )
            }
        case .rollback:
            guard let before = journal.before,
                  let target = journal.target,
                  target.installationID == before.installationID,
                  target.generation == before.generation - 1 else {
                throw DaemonLifecycleError.conflict(
                    "the rollback journal is not the exact prior generation"
                )
            }
        case .bootstrap, .start, .kickstart:
            try validateSameGeneration(journal)
            guard journal.target?.desiredLoaded == true,
                  journal.target?.disabled == false else {
                throw DaemonLifecycleError.conflict(
                    "the start journal target is invalid"
                )
            }
        case .stop:
            try validateSameGeneration(journal)
            guard journal.target?.desiredLoaded == false else {
                throw DaemonLifecycleError.conflict(
                    "the stop journal target is invalid"
                )
            }
        case .disable:
            try validateSameGeneration(journal)
            guard journal.target?.desiredLoaded == false,
                  journal.target?.disabled == true else {
                throw DaemonLifecycleError.conflict(
                    "the disable journal target is invalid"
                )
            }
        case .repair:
            try validateSameGeneration(journal)
            guard journal.target == journal.before else {
                throw DaemonLifecycleError.conflict(
                    "the repair journal changed the owned generation"
                )
            }
        case .status, .validate:
            throw DaemonLifecycleError.conflict(
                "read-only operations cannot create a lifecycle journal"
            )
        }
    }

    private func validateSameGeneration(
        _ journal: DaemonLifecycleJournal
    ) throws {
        guard let before = journal.before,
              let target = journal.target,
              target.installationID == before.installationID,
              target.generation == before.generation else {
            throw DaemonLifecycleError.conflict(
                "the lifecycle journal changed generation without upgrade or rollback"
            )
        }
    }

    private func readCodable<Value: Decodable>(
        _ type: Value.Type,
        from path: String,
        shape: DaemonLifecycleRecordShape
    ) throws -> Value? {
        guard let data = try readSecureFile(
            path,
            maximumBytes: 4 * 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        ) else { return nil }
        guard shape.validate(data) else {
            throw DaemonLifecycleError.conflict("invalid lifecycle record at \(path)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DaemonLifecycleError.conflict("invalid lifecycle record at \(path)")
        }
    }

    private func writeCodable<Value: Encodable>(
        _ value: Value,
        to path: String
    ) throws {
        try writeAtomic(try encoded(value), to: path)
    }

    private func writeCodableNew<Value: Encodable>(
        _ value: Value,
        to path: String
    ) throws {
        try writeAtomic(try encoded(value), to: path, replaceExisting: false)
    }

    private func encoded<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func publishPropertyList(
        _ data: Data,
        before: DaemonLifecycleOwnershipRecord?,
        target: DaemonLifecycleOwnershipRecord,
        recovering: Bool
    ) throws {
        if let existing = try readSecureFile(
            layout.propertyListPath,
            maximumBytes: 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        ) {
            let digest = sha256(existing)
            let accepted = digest == target.propertyListSHA256
                || digest == before?.propertyListSHA256
            guard accepted else {
                throw DaemonLifecycleError.conflict(
                    "the managed plist changed before publication"
                )
            }
            if digest == target.propertyListSHA256 { return }
        } else if before != nil && !recovering {
            throw DaemonLifecycleError.conflict(
                "the managed plist disappeared before publication"
            )
        }
        try writeAtomic(data, to: layout.propertyListPath)
    }

    private func ensureLifecycleDirectories() throws {
        try validateLayout()
        try ensureOwnedDirectory(
            URL(fileURLWithPath: layout.propertyListPath).deletingLastPathComponent().path,
            finalMode: 0o700
        )
        try ensureOwnedDirectory(layout.lifecycleDirectory, finalMode: 0o700)
        try ensureOwnedDirectory(layout.logDirectory, finalMode: 0o700)
    }

    private func prepareLogFiles(allowExisting: Bool) throws {
        for path in [layout.standardOutputPath, layout.standardErrorPath] {
            if secureEntryExists(path) {
                guard allowExisting,
                      try readSecureFile(
                        path,
                        maximumBytes: 16 * 1_048_576,
                        allowRootOwner: false,
                        requireMode: 0o600
                      ) != nil else {
                    throw DaemonLifecycleError.conflict(
                        "a daemon log path already exists without exact ownership"
                    )
                }
            } else {
                try writeAtomic(Data(), to: path)
            }
        }
    }

    private func validateLayout() throws {
        guard layout.schemaVersion == 1,
              layout.userID == UInt32(geteuid()),
              layout.label == "dev.hostwright.daemon",
              layout.domain == "gui/\(geteuid())",
              layout.homebrewLabel == "homebrew.mxcl.hostwright" else {
            throw DaemonLifecycleError.invalidRequest(
                "the lifecycle layout is not the exact current-user contract"
            )
        }
        let home: String
        do {
            home = try HostwrightLocalPathResolver.normalizedAbsolutePath(
                layout.homeDirectory,
                role: "daemon lifecycle home"
            )
        } catch {
            throw DaemonLifecycleError.unsafePath(layout.homeDirectory)
        }
        guard layout == DaemonLifecycleLayout(
            homeDirectory: home,
            userID: UInt32(geteuid())
        ) else {
            throw DaemonLifecycleError.invalidRequest(
                "the lifecycle layout paths are not the exact current-user contract"
            )
        }
        let requiredPrefix = home == "/" ? "/" : home + "/"
        for path in [
            layout.propertyListPath,
            layout.lifecycleDirectory,
            layout.journalPath,
            layout.statusPath,
            layout.rollbackPath,
            layout.logDirectory,
            layout.standardOutputPath,
            layout.standardErrorPath,
            layout.homebrewPropertyListPath
        ] {
            guard path.hasPrefix(requiredPrefix),
                  (try? HostwrightLocalPathResolver.normalizedAbsolutePath(
                    path,
                    role: "daemon lifecycle path"
                  )) == path else {
                throw DaemonLifecycleError.unsafePath(path)
            }
        }
    }

    private func ensureOwnedDirectory(
        _ path: String,
        finalMode: mode_t
    ) throws {
        let normalized = try HostwrightLocalPathResolver.normalizedAbsolutePath(
            path,
            role: "daemon lifecycle directory"
        )
        let home = layout.homeDirectory
        guard normalized == home || normalized.hasPrefix(home + "/") else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        var current = home
        try validateDirectory(current, requirePrivate: true)
        let relative = normalized.dropFirst(home.count)
        for component in relative.split(separator: "/") {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(String(component), isDirectory: true).path
            var metadata = stat()
            if lstat(current, &metadata) != 0 {
                guard errno == ENOENT,
                      mkdir(current, finalMode) == 0 else {
                    throw DaemonLifecycleError.unsafePath(current)
                }
            }
            try validateDirectory(current, requirePrivate: true)
        }
    }

    private func validateDirectory(_ path: String, requirePrivate: Bool) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              (!requirePrivate || metadata.st_mode & (S_IWGRP | S_IWOTH) == 0) else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                atPath: path,
                role: "daemon lifecycle directory"
            )
        } catch {
            throw DaemonLifecycleError.unsafePath(path)
        }
    }

    private func readSecureFile(
        _ path: String,
        maximumBytes: Int,
        allowRootOwner: Bool,
        requireMode: mode_t?
    ) throws -> Data? {
        var named = stat()
        guard lstat(path, &named) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw DaemonLifecycleError.unsafePath(path)
        }
        try validateCanonicalDirectory(
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        )
        let ownerAccepted = named.st_uid == geteuid()
            || (allowRootOwner && named.st_uid == 0)
        guard named.st_mode & S_IFMT == S_IFREG,
              ownerAccepted,
              named.st_nlink == 1,
              named.st_mode & (S_IWGRP | S_IWOTH) == 0,
              requireMode == nil || named.st_mode & 0o777 == requireMode,
              named.st_size >= 0,
              named.st_size <= maximumBytes else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DaemonLifecycleError.unsafePath(path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == named.st_dev,
              opened.st_ino == named.st_ino,
              opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == named.st_uid,
              opened.st_nlink == 1,
              opened.st_size == named.st_size else {
            try? handle.close()
            throw DaemonLifecycleError.unsafePath(path)
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: path,
                role: "daemon lifecycle file"
            )
        } catch {
            try? handle.close()
            throw DaemonLifecycleError.unsafePath(path)
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        var final = stat()
        guard lstat(path, &final) == 0,
              final.st_dev == opened.st_dev,
              final.st_ino == opened.st_ino,
              final.st_uid == opened.st_uid,
              final.st_mode == opened.st_mode,
              final.st_nlink == 1,
              final.st_size == opened.st_size,
              data.count == Int(opened.st_size) else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        return data
    }

    private func writeAtomic(
        _ data: Data,
        to path: String,
        replaceExisting: Bool = true
    ) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try validateCanonicalDirectory(parent)
        try validateDirectory(parent, requirePrivate: true)
        if secureEntryExists(path) {
            _ = try readSecureFile(
                path,
                maximumBytes: 16 * 1_048_576,
                allowRootOwner: false,
                requireMode: 0o600
            )
        }
        let temporary = parent + "/.\(URL(fileURLWithPath: path).lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw DaemonLifecycleError.unsafePath(temporary) }
        var published = false
        defer {
            close(descriptor)
            if !published { unlink(temporary) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard count > 0 else { throw DaemonLifecycleError.unsafePath(temporary) }
                offset += count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw DaemonLifecycleError.unsafePath(path)
        }
        do {
            try HostwrightLocalFilesystemPolicy.validateNoAccessGrantingACL(
                fileDescriptor: descriptor,
                path: temporary,
                role: "new daemon lifecycle file"
            )
        } catch {
            throw DaemonLifecycleError.unsafePath(path)
        }
        let renameResult = replaceExisting
            ? rename(temporary, path)
            : renamex_np(temporary, path, UInt32(RENAME_EXCL))
        guard renameResult == 0 else {
            if !replaceExisting && errno == EEXIST {
                throw DaemonLifecycleError.recoveryRequired
            }
            throw DaemonLifecycleError.unsafePath(path)
        }
        published = true
        let parentDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw DaemonLifecycleError.unsafePath(parent) }
        defer { close(parentDescriptor) }
        guard fsync(parentDescriptor) == 0 else {
            throw DaemonLifecycleError.unsafePath(parent)
        }
    }

    private func removeSecureFileIfPresent(
        _ path: String,
        expectedSHA256: String?
    ) throws {
        guard let data = try readSecureFile(
            path,
            maximumBytes: 16 * 1_048_576,
            allowRootOwner: false,
            requireMode: 0o600
        ) else { return }
        if let expectedSHA256, sha256(data) != expectedSHA256 {
            throw DaemonLifecycleError.conflict(
                "refusing to remove changed lifecycle file at \(path)"
            )
        }
        guard unlink(path) == 0 else { throw DaemonLifecycleError.unsafePath(path) }
        try synchronizeParentDirectory(of: path)
    }

    private func synchronizeParentDirectory(of path: String) throws {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try validateCanonicalDirectory(parent)
        let descriptor = open(
            parent,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DaemonLifecycleError.unsafePath(parent)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DaemonLifecycleError.unsafePath(parent)
        }
    }

    private func removeDirectoryIfEmpty(_ path: String) throws {
        guard secureEntryExists(path) else { return }
        try validateCanonicalDirectory(path)
        guard rmdir(path) == 0 else {
            if errno == ENOTEMPTY || errno == EEXIST { return }
            throw DaemonLifecycleError.unsafePath(path)
        }
    }

    private func validateCanonicalDirectory(_ path: String) throws {
        do {
            guard try SecureExecutableResolver.verifyWorkingDirectory(path: path) == path else {
                throw DaemonLifecycleError.unsafePath(path)
            }
        } catch let error as DaemonLifecycleError {
            throw error
        } catch {
            throw DaemonLifecycleError.unsafePath(path)
        }
    }

    private func secureEntryExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requireValue(_ value: String?, role: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw DaemonLifecycleError.invalidRequest("\(role) is required")
        }
        return value
    }

    private func makeStatus(
        record: DaemonLifecycleOwnershipRecord?,
        readiness: DaemonLifecycleReadiness,
        processID: Int32?,
        pendingOperation: DaemonLifecycleOperation?,
        reasonCode: DaemonLifecycleReasonCode
    ) -> DaemonLifecycleStatus {
        DaemonLifecycleStatus(
            label: layout.label,
            domain: layout.domain,
            readiness: readiness,
            propertyListPath: layout.propertyListPath,
            daemonExecutablePath: record?.daemonExecutablePath,
            configPath: record?.configPath,
            generation: record?.generation,
            installationID: record?.installationID,
            processID: processID,
            pendingOperation: pendingOperation,
            reasonCode: reasonCode
        )
    }

}

private extension DaemonLifecycleCheckpoint {
    var provesManagedLogsWerePrepared: Bool {
        switch self {
        case .propertyListPublished,
             .disabledStatePublished,
             .serviceStarted,
             .verified,
             .statusPublished:
            true
        case .intentRecorded, .rollbackPublished, .serviceStopped:
            false
        }
    }
}
