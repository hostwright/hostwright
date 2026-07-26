import CryptoKit
import Foundation
import HostwrightCore
import HostwrightSecrets
import HostwrightState
import HostwrightStorage

public struct StorageDestructiveCLIOptions: Equatable, Sendable {
    public let dryRun: Bool
    public let confirmationPlanSHA256: String?

    public init(
        dryRun: Bool,
        confirmationPlanSHA256: String?
    ) {
        self.dryRun = dryRun
        self.confirmationPlanSHA256 = confirmationPlanSHA256
    }
}

public struct StorageRestoreTargetCLI: Codable, Equatable, Sendable {
    public let sourceVolumeID: String
    public let targetVolumeID: String

    public init(sourceVolumeID: String, targetVolumeID: String) {
        self.sourceVolumeID = sourceVolumeID
        self.targetVolumeID = targetVolumeID
    }
}

public enum StorageSnapshotCLIAction: Equatable, Sendable {
    case create(volumeID: String, snapshotID: String, name: String)
    case list(volumeID: String)
    case inspect(volumeID: String, snapshotID: String)
    case retain(volumeID: String, snapshotID: String, owner: String)
    case export(volumeID: String, snapshotID: String, outputPath: String)
    case restore(
        sourceVolumeID: String,
        snapshotID: String,
        targetVolumeID: String,
        referenceID: String,
        confirmation: StorageDestructiveCLIOptions
    )
    case delete(
        volumeID: String,
        snapshotID: String,
        confirmation: StorageDestructiveCLIOptions
    )
}

public enum StorageBackupCLIAction: Equatable, Sendable {
    case create(
        volumeIDs: [String],
        backupID: String,
        name: String,
        keyReference: String,
        remoteDestination: StorageBackupRemoteDestination?
    )
    case list(volumeID: String)
    case inspect(volumeID: String, backupID: String)
    case verify(
        volumeID: String,
        backupID: String,
        keyReference: String,
        remoteDestination: StorageBackupRemoteDestination?
    )
    case retain(
        volumeID: String,
        backupID: String,
        owner: String,
        remoteDestination: StorageBackupRemoteDestination?
    )
    case restore(
        backupID: String,
        keyReference: String,
        targets: [StorageRestoreTargetCLI],
        remoteDestination: StorageBackupRemoteDestination?,
        confirmation: StorageDestructiveCLIOptions
    )
    case delete(
        volumeID: String,
        backupID: String,
        remoteDestination: StorageBackupRemoteDestination?,
        confirmation: StorageDestructiveCLIOptions
    )
}

public enum StorageCLIAction: Equatable, Sendable {
    case list(projectID: String?)
    case inspect(volumeID: String)
    case capacity
    case health
    case recover(volumeID: String, idempotencyKey: String)
    case delete(
        volumeID: String,
        confirmation: StorageDestructiveCLIOptions
    )
    case prune(confirmation: StorageDestructiveCLIOptions)
    case snapshot(StorageSnapshotCLIAction)
    case backup(StorageBackupCLIAction)
}

public struct StorageCLIOptions: Equatable, Sendable {
    public let action: StorageCLIAction
    public let stateDatabasePath: String?
    public let timeoutSeconds: Int
    public let output: CLIOutputFormat

    public init(
        action: StorageCLIAction,
        stateDatabasePath: String?,
        timeoutSeconds: Int,
        output: CLIOutputFormat
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.timeoutSeconds = timeoutSeconds
        self.output = output
    }
}

enum StorageCLIParser {
    static func parse(arguments: [String]) throws -> StorageCLIOptions {
        guard arguments.count >= 2 else {
            throw CLIUsageError("volume requires a subcommand.")
        }
        switch arguments[1] {
        case "list":
            return try list(arguments)
        case "inspect":
            return try oneVolume(arguments, action: StorageCLIAction.inspect)
        case "capacity":
            return try noOperand(arguments, action: .capacity)
        case "health":
            return try noOperand(arguments, action: .health)
        case "recover":
            return try recover(arguments)
        case "delete":
            return try delete(arguments)
        case "prune":
            return try prune(arguments)
        case "snapshot":
            return try snapshot(arguments)
        case "backup":
            return try backup(arguments)
        default:
            throw CLIUsageError(
                "volume supports list, inspect, capacity, health, recover, delete, prune, snapshot, and backup."
            )
        }
    }

    private static func list(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var projectID: String?
        var index = 2
        while index < arguments.count {
            if arguments[index] == "--project" {
                projectID = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--project",
                    existing: projectID,
                    command: "volume list"
                )
                try requireIdentifier(projectID!, role: "project")
                index += 2
            } else {
                index = try common.consume(arguments, index: index, command: "volume list")
            }
        }
        return common.options(action: .list(projectID: projectID))
    }

    private static func oneVolume(
        _ arguments: [String],
        action: (String) -> StorageCLIAction
    ) throws -> StorageCLIOptions {
        var common = Common()
        var volumeID: String?
        var index = 2
        while index < arguments.count {
            if arguments[index].hasPrefix("--") {
                index = try common.consume(arguments, index: index, command: "volume inspect")
            } else {
                guard volumeID == nil else {
                    throw CLIUsageError("volume inspect accepts exactly one volume UUID.")
                }
                volumeID = try canonicalUUID(arguments[index], role: "volume")
                index += 1
            }
        }
        guard let volumeID else {
            throw CLIUsageError("volume inspect requires one volume UUID.")
        }
        return common.options(action: action(volumeID))
    }

    private static func noOperand(
        _ arguments: [String],
        action: StorageCLIAction
    ) throws -> StorageCLIOptions {
        var common = Common()
        var index = 2
        while index < arguments.count {
            index = try common.consume(arguments, index: index, command: "volume \(arguments[1])")
        }
        return common.options(action: action)
    }

    private static func recover(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var volumeID: String?
        var idempotencyKey: String?
        var index = 2
        while index < arguments.count {
            switch arguments[index] {
            case "--idempotency-key":
                idempotencyKey = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--idempotency-key",
                    existing: idempotencyKey,
                    command: "volume recover"
                )
                try requireBoundedText(
                    idempotencyKey!,
                    role: "recovery idempotency key",
                    maximumBytes: 256
                )
                index += 2
            default:
                if arguments[index].hasPrefix("--") {
                    index = try common.consume(arguments, index: index, command: "volume recover")
                } else {
                    guard volumeID == nil else {
                        throw CLIUsageError("volume recover accepts exactly one volume UUID.")
                    }
                    volumeID = try canonicalUUID(arguments[index], role: "volume")
                    index += 1
                }
            }
        }
        guard let volumeID, let idempotencyKey else {
            throw CLIUsageError(
                "volume recover requires one volume UUID and --idempotency-key."
            )
        }
        return common.options(
            action: .recover(
                volumeID: volumeID,
                idempotencyKey: idempotencyKey
            )
        )
    }

    private static func delete(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var confirmation = Confirmation()
        var volumeID: String?
        var index = 2
        while index < arguments.count {
            if try confirmation.consumeIfPresent(arguments, index: &index, command: "volume delete") {
                continue
            }
            if arguments[index].hasPrefix("--") {
                index = try common.consume(arguments, index: index, command: "volume delete")
            } else {
                guard volumeID == nil else {
                    throw CLIUsageError("volume delete accepts exactly one volume UUID.")
                }
                volumeID = try canonicalUUID(arguments[index], role: "volume")
                index += 1
            }
        }
        guard let volumeID else {
            throw CLIUsageError("volume delete requires one volume UUID.")
        }
        return common.options(
            action: .delete(
                volumeID: volumeID,
                confirmation: try confirmation.finalize(command: "volume delete")
            )
        )
    }

    private static func prune(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var confirmation = Confirmation()
        var index = 2
        while index < arguments.count {
            if try confirmation.consumeIfPresent(arguments, index: &index, command: "volume prune") {
                continue
            }
            index = try common.consume(arguments, index: index, command: "volume prune")
        }
        return common.options(
            action: .prune(
                confirmation: try confirmation.finalize(command: "volume prune")
            )
        )
    }

    private static func snapshot(_ arguments: [String]) throws -> StorageCLIOptions {
        guard arguments.count >= 3 else {
            throw CLIUsageError("volume snapshot requires a subcommand.")
        }
        switch arguments[2] {
        case "create":
            return try snapshotCreate(arguments)
        case "list":
            return try snapshotRead(arguments, operation: "list")
        case "inspect":
            return try snapshotRead(arguments, operation: "inspect")
        case "retain":
            return try snapshotRetain(arguments)
        case "export":
            return try snapshotExport(arguments)
        case "restore":
            return try snapshotRestore(arguments)
        case "delete":
            return try snapshotDelete(arguments)
        default:
            throw CLIUsageError(
                "volume snapshot supports create, list, inspect, retain, export, restore, and delete."
            )
        }
    }

    private static func snapshotCreate(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var volumeID: String?
        var snapshotID: String?
        var name: String?
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--snapshot-id":
                snapshotID = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--snapshot-id",
                    existing: snapshotID,
                    command: "volume snapshot create"
                )
                snapshotID = try canonicalUUID(snapshotID!, role: "snapshot")
                index += 2
            case "--name":
                name = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--name",
                    existing: name,
                    command: "volume snapshot create"
                )
                try requireName(name!, role: "snapshot")
                index += 2
            default:
                if arguments[index].hasPrefix("--") {
                    index = try common.consume(
                        arguments,
                        index: index,
                        command: "volume snapshot create"
                    )
                } else {
                    guard volumeID == nil else {
                        throw CLIUsageError(
                            "volume snapshot create accepts exactly one volume UUID."
                        )
                    }
                    volumeID = try canonicalUUID(arguments[index], role: "volume")
                    index += 1
                }
            }
        }
        guard let volumeID, let snapshotID, let name else {
            throw CLIUsageError(
                "volume snapshot create requires a volume UUID, --snapshot-id, and --name."
            )
        }
        return common.options(
            action: .snapshot(
                .create(
                    volumeID: volumeID,
                    snapshotID: snapshotID,
                    name: name
                )
            )
        )
    }

    private static func snapshotRead(
        _ arguments: [String],
        operation: String
    ) throws -> StorageCLIOptions {
        var common = Common()
        var values: [String] = []
        var index = 3
        while index < arguments.count {
            if arguments[index].hasPrefix("--") {
                index = try common.consume(
                    arguments,
                    index: index,
                    command: "volume snapshot \(operation)"
                )
            } else {
                values.append(try canonicalUUID(arguments[index], role: values.isEmpty ? "volume" : "snapshot"))
                index += 1
            }
        }
        if operation == "list", values.count == 1 {
            return common.options(
                action: .snapshot(.list(volumeID: values[0]))
            )
        }
        if operation == "inspect", values.count == 2 {
            return common.options(
                action: .snapshot(
                    .inspect(volumeID: values[0], snapshotID: values[1])
                )
            )
        }
        throw CLIUsageError(
            "volume snapshot \(operation) requires \(operation == "list" ? "one volume UUID" : "a volume UUID and snapshot UUID")."
        )
    }

    private static func snapshotRetain(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var values: [String] = []
        var owner: String?
        var index = 3
        while index < arguments.count {
            if arguments[index] == "--owner" {
                owner = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--owner",
                    existing: owner,
                    command: "volume snapshot retain"
                )
                try requireIdentifier(owner!, role: "retainer")
                index += 2
            } else if arguments[index].hasPrefix("--") {
                index = try common.consume(arguments, index: index, command: "volume snapshot retain")
            } else {
                values.append(try canonicalUUID(arguments[index], role: values.isEmpty ? "volume" : "snapshot"))
                index += 1
            }
        }
        guard values.count == 2, let owner else {
            throw CLIUsageError(
                "volume snapshot retain requires volume UUID, snapshot UUID, and --owner."
            )
        }
        return common.options(
            action: .snapshot(
                .retain(volumeID: values[0], snapshotID: values[1], owner: owner)
            )
        )
    }

    private static func snapshotExport(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var values: [String] = []
        var outputPath: String?
        var index = 3
        while index < arguments.count {
            if arguments[index] == "--output" {
                outputPath = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--output",
                    existing: outputPath,
                    command: "volume snapshot export"
                )
                try requireAbsoluteNormalizedPath(outputPath!, role: "snapshot export")
                index += 2
            } else if arguments[index].hasPrefix("--") {
                index = try common.consume(arguments, index: index, command: "volume snapshot export")
            } else {
                values.append(try canonicalUUID(arguments[index], role: values.isEmpty ? "volume" : "snapshot"))
                index += 1
            }
        }
        guard values.count == 2, let outputPath else {
            throw CLIUsageError(
                "volume snapshot export requires volume UUID, snapshot UUID, and --output."
            )
        }
        return common.options(
            action: .snapshot(
                .export(
                    volumeID: values[0],
                    snapshotID: values[1],
                    outputPath: outputPath
                )
            )
        )
    }

    private static func snapshotRestore(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var confirmation = Confirmation()
        var sourceVolumeID: String?
        var snapshotID: String?
        var targetVolumeID: String?
        var referenceID: String?
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--source-volume":
                sourceVolumeID = try uuidValue(
                    arguments,
                    index: index,
                    flag: "--source-volume",
                    existing: sourceVolumeID,
                    command: "volume snapshot restore"
                )
                index += 2
            case "--to-volume":
                targetVolumeID = try uuidValue(
                    arguments,
                    index: index,
                    flag: "--to-volume",
                    existing: targetVolumeID,
                    command: "volume snapshot restore"
                )
                index += 2
            case "--reference-id":
                referenceID = try uuidValue(
                    arguments,
                    index: index,
                    flag: "--reference-id",
                    existing: referenceID,
                    command: "volume snapshot restore"
                )
                index += 2
            default:
                if try confirmation.consumeIfPresent(arguments, index: &index, command: "volume snapshot restore") {
                    continue
                }
                if arguments[index].hasPrefix("--") {
                    index = try common.consume(arguments, index: index, command: "volume snapshot restore")
                } else {
                    guard snapshotID == nil else {
                        throw CLIUsageError(
                            "volume snapshot restore accepts exactly one snapshot UUID."
                        )
                    }
                    snapshotID = try canonicalUUID(arguments[index], role: "snapshot")
                    index += 1
                }
            }
        }
        guard let sourceVolumeID, let snapshotID,
              let targetVolumeID, let referenceID else {
            throw CLIUsageError(
                "volume snapshot restore requires snapshot UUID, --source-volume, --to-volume, and --reference-id."
            )
        }
        return common.options(
            action: .snapshot(
                .restore(
                    sourceVolumeID: sourceVolumeID,
                    snapshotID: snapshotID,
                    targetVolumeID: targetVolumeID,
                    referenceID: referenceID,
                    confirmation: try confirmation.finalize(
                        command: "volume snapshot restore"
                    )
                )
            )
        )
    }

    private static func snapshotDelete(_ arguments: [String]) throws -> StorageCLIOptions {
        let parsed = try destructiveDataProtection(
            arguments,
            noun: "snapshot"
        )
        return parsed.common.options(
            action: .snapshot(
                .delete(
                    volumeID: parsed.volumeID,
                    snapshotID: parsed.resourceID,
                    confirmation: parsed.confirmation
                )
            )
        )
    }

    private static func backup(_ arguments: [String]) throws -> StorageCLIOptions {
        guard arguments.count >= 3 else {
            throw CLIUsageError("volume backup requires a subcommand.")
        }
        switch arguments[2] {
        case "create":
            return try backupCreate(arguments)
        case "list":
            return try backupRead(arguments, operation: "list")
        case "inspect":
            return try backupRead(arguments, operation: "inspect")
        case "verify":
            return try backupVerify(arguments)
        case "retain":
            return try backupRetain(arguments)
        case "restore":
            return try backupRestore(arguments)
        case "delete":
            return try backupDelete(arguments)
        default:
            throw CLIUsageError(
                "volume backup supports create, list, inspect, verify, retain, restore, and delete."
            )
        }
    }

    private static func backupCreate(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var volumes: [String] = []
        var backupID: String?
        var name: String?
        var keyReference: String?
        var remote = BackupRemote()
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--volume":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("volume backup create requires a value after --volume.")
                }
                volumes.append(try canonicalUUID(arguments[index + 1], role: "volume"))
                index += 2
            case "--backup-id":
                backupID = try uuidValue(
                    arguments,
                    index: index,
                    flag: "--backup-id",
                    existing: backupID,
                    command: "volume backup create"
                )
                index += 2
            case "--name":
                name = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--name",
                    existing: name,
                    command: "volume backup create"
                )
                try requireName(name!, role: "backup")
                index += 2
            case "--key-ref":
                keyReference = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--key-ref",
                    existing: keyReference,
                    command: "volume backup create"
                )
                try requireSecretReference(keyReference!)
                index += 2
            default:
                if try remote.consumeIfPresent(
                    arguments,
                    index: &index,
                    command: "volume backup create"
                ) {
                    continue
                }
                index = try common.consume(
                    arguments,
                    index: index,
                    command: "volume backup create"
                )
            }
        }
        volumes = Array(Set(volumes)).sorted()
        guard !volumes.isEmpty, volumes.count <= 256,
              let backupID, let name, let keyReference else {
            throw CLIUsageError(
                "volume backup create requires 1-256 --volume values, --backup-id, --name, and --key-ref."
            )
        }
        return common.options(
            action: .backup(
                .create(
                    volumeIDs: volumes,
                    backupID: backupID,
                    name: name,
                    keyReference: keyReference,
                    remoteDestination: try remote.finalize(
                        command: "volume backup create"
                    )
                )
            )
        )
    }

    private static func backupRead(
        _ arguments: [String],
        operation: String
    ) throws -> StorageCLIOptions {
        let parsed = try readDataProtection(
            arguments,
            noun: "backup",
            operation: operation
        )
        if operation == "list" {
            return parsed.common.options(
                action: .backup(.list(volumeID: parsed.volumeID))
            )
        }
        return parsed.common.options(
            action: .backup(
                .inspect(
                    volumeID: parsed.volumeID,
                    backupID: parsed.resourceID!
                )
            )
        )
    }

    private static func backupVerify(_ arguments: [String]) throws -> StorageCLIOptions {
        let parsed = try readDataProtection(
            arguments,
            noun: "backup",
            operation: "verify",
            acceptedExtraFlag: "--key-ref",
            acceptRemoteDestination: true
        )
        guard let keyReference = parsed.extraValue else {
            throw CLIUsageError("volume backup verify requires --key-ref.")
        }
        try requireSecretReference(keyReference)
        return parsed.common.options(
            action: .backup(
                .verify(
                    volumeID: parsed.volumeID,
                    backupID: parsed.resourceID!,
                    keyReference: keyReference,
                    remoteDestination:
                        parsed.remoteDestination
                )
            )
        )
    }

    private static func backupRetain(_ arguments: [String]) throws -> StorageCLIOptions {
        let parsed = try readDataProtection(
            arguments,
            noun: "backup",
            operation: "retain",
            acceptedExtraFlag: "--owner",
            acceptRemoteDestination: true
        )
        guard let owner = parsed.extraValue else {
            throw CLIUsageError("volume backup retain requires --owner.")
        }
        try requireIdentifier(owner, role: "retainer")
        return parsed.common.options(
            action: .backup(
                .retain(
                    volumeID: parsed.volumeID,
                    backupID: parsed.resourceID!,
                    owner: owner,
                    remoteDestination:
                        parsed.remoteDestination
                )
            )
        )
    }

    private static func backupRestore(_ arguments: [String]) throws -> StorageCLIOptions {
        var common = Common()
        var confirmation = Confirmation()
        var backupID: String?
        var keyReference: String?
        var targets: [StorageRestoreTargetCLI] = []
        var remote = BackupRemote()
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--key-ref":
                keyReference = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--key-ref",
                    existing: keyReference,
                    command: "volume backup restore"
                )
                try requireSecretReference(keyReference!)
                index += 2
            case "--target":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError("volume backup restore requires source=target after --target.")
                }
                let parts = arguments[index + 1].split(
                    separator: "=",
                    omittingEmptySubsequences: false
                )
                guard parts.count == 2 else {
                    throw CLIUsageError("volume backup restore --target requires source=target UUIDs.")
                }
                targets.append(
                    StorageRestoreTargetCLI(
                        sourceVolumeID: try canonicalUUID(String(parts[0]), role: "source volume"),
                        targetVolumeID: try canonicalUUID(String(parts[1]), role: "target volume")
                    )
                )
                index += 2
            default:
                if try confirmation.consumeIfPresent(arguments, index: &index, command: "volume backup restore") {
                    continue
                }
                if try remote.consumeIfPresent(
                    arguments,
                    index: &index,
                    command: "volume backup restore"
                ) {
                    continue
                }
                if arguments[index].hasPrefix("--") {
                    index = try common.consume(arguments, index: index, command: "volume backup restore")
                } else {
                    guard backupID == nil else {
                        throw CLIUsageError("volume backup restore accepts exactly one backup UUID.")
                    }
                    backupID = try canonicalUUID(arguments[index], role: "backup")
                    index += 1
                }
            }
        }
        targets.sort {
            $0.sourceVolumeID == $1.sourceVolumeID
                ? $0.targetVolumeID < $1.targetVolumeID
                : $0.sourceVolumeID < $1.sourceVolumeID
        }
        guard let backupID, let keyReference,
              !targets.isEmpty, targets.count <= 256,
              Set(targets.map(\.sourceVolumeID)).count == targets.count,
              Set(targets.map(\.targetVolumeID)).count == targets.count else {
            throw CLIUsageError(
                "volume backup restore requires backup UUID, --key-ref, and 1-256 unique --target source=target mappings."
            )
        }
        return common.options(
            action: .backup(
                .restore(
                    backupID: backupID,
                    keyReference: keyReference,
                    targets: targets,
                    remoteDestination: try remote.finalize(
                        command: "volume backup restore"
                    ),
                    confirmation: try confirmation.finalize(
                        command: "volume backup restore"
                    )
                )
            )
        )
    }

    private static func backupDelete(_ arguments: [String]) throws -> StorageCLIOptions {
        let parsed = try destructiveDataProtection(
            arguments,
            noun: "backup",
            acceptRemoteDestination: true
        )
        return parsed.common.options(
            action: .backup(
                .delete(
                    volumeID: parsed.volumeID,
                    backupID: parsed.resourceID,
                    remoteDestination:
                        parsed.remoteDestination,
                    confirmation: parsed.confirmation
                )
            )
        )
    }

    private static func destructiveDataProtection(
        _ arguments: [String],
        noun: String,
        acceptRemoteDestination: Bool = false
    ) throws -> (
        common: Common,
        volumeID: String,
        resourceID: String,
        remoteDestination: StorageBackupRemoteDestination?,
        confirmation: StorageDestructiveCLIOptions
    ) {
        var common = Common()
        var confirmation = Confirmation()
        var remote = BackupRemote()
        var values: [String] = []
        var index = 3
        while index < arguments.count {
            if try confirmation.consumeIfPresent(
                arguments,
                index: &index,
                command: "volume \(noun) delete"
            ) {
                continue
            }
            if acceptRemoteDestination,
               try remote.consumeIfPresent(
                   arguments,
                   index: &index,
                   command: "volume \(noun) delete"
               ) {
                continue
            }
            if arguments[index].hasPrefix("--") {
                index = try common.consume(
                    arguments,
                    index: index,
                    command: "volume \(noun) delete"
                )
            } else {
                values.append(
                    try canonicalUUID(
                        arguments[index],
                        role: values.isEmpty ? "volume" : noun
                    )
                )
                index += 1
            }
        }
        guard values.count == 2 else {
            throw CLIUsageError(
                "volume \(noun) delete requires volume UUID and \(noun) UUID."
            )
        }
        return (
            common,
            values[0],
            values[1],
            try remote.finalize(
                command: "volume \(noun) delete"
            ),
            try confirmation.finalize(command: "volume \(noun) delete")
        )
    }

    private static func readDataProtection(
        _ arguments: [String],
        noun: String,
        operation: String,
        acceptedExtraFlag: String? = nil,
        acceptRemoteDestination: Bool = false
    ) throws -> (
        common: Common,
        volumeID: String,
        resourceID: String?,
        extraValue: String?,
        remoteDestination: StorageBackupRemoteDestination?
    ) {
        var common = Common()
        var values: [String] = []
        var extraValue: String?
        var remote = BackupRemote()
        var index = 3
        while index < arguments.count {
            if let acceptedExtraFlag,
               arguments[index] == acceptedExtraFlag {
                extraValue = try uniqueValue(
                    arguments,
                    index: index,
                    flag: acceptedExtraFlag,
                    existing: extraValue,
                    command: "volume \(noun) \(operation)"
                )
                index += 2
            } else if acceptRemoteDestination,
                      try remote.consumeIfPresent(
                          arguments,
                          index: &index,
                          command: "volume \(noun) \(operation)"
                      ) {
                continue
            } else if arguments[index].hasPrefix("--") {
                index = try common.consume(
                    arguments,
                    index: index,
                    command: "volume \(noun) \(operation)"
                )
            } else {
                values.append(
                    try canonicalUUID(
                        arguments[index],
                        role: values.isEmpty ? "volume" : noun
                    )
                )
                index += 1
            }
        }
        let expected = operation == "list" ? 1 : 2
        guard values.count == expected else {
            throw CLIUsageError(
                "volume \(noun) \(operation) requires \(expected == 1 ? "one volume UUID" : "volume UUID and \(noun) UUID")."
            )
        }
        return (
            common,
            values[0],
            values.count == 2 ? values[1] : nil,
            extraValue,
            try remote.finalize(
                command: "volume \(noun) \(operation)"
            )
        )
    }

    private struct BackupRemote {
        var endpoint: String?
        var bucket: String?
        var region: String?
        var prefix: String?
        var accessKeyReference: String?
        var secretKeyReference: String?

        mutating func consumeIfPresent(
            _ arguments: [String],
            index: inout Int,
            command: String
        ) throws -> Bool {
            let flag = arguments[index]
            switch flag {
            case "--remote-s3-endpoint":
                endpoint = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: endpoint,
                    command: command
                )
            case "--remote-s3-bucket":
                bucket = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: bucket,
                    command: command
                )
            case "--remote-s3-region":
                region = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: region,
                    command: command
                )
            case "--remote-s3-prefix":
                prefix = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: prefix,
                    command: command
                )
            case "--remote-s3-access-key-ref":
                accessKeyReference = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: accessKeyReference,
                    command: command
                )
            case "--remote-s3-secret-key-ref":
                secretKeyReference = try uniqueValue(
                    arguments,
                    index: index,
                    flag: flag,
                    existing: secretKeyReference,
                    command: command
                )
            default:
                return false
            }
            index += 2
            return true
        }

        func finalize(
            command: String
        ) throws -> StorageBackupRemoteDestination? {
            let selected = [
                endpoint,
                bucket,
                region,
                prefix,
                accessKeyReference,
                secretKeyReference,
            ].contains { $0 != nil }
            guard selected else {
                return nil
            }
            guard let endpoint,
                  let bucket,
                  let region,
                  let accessKeyReference,
                  let secretKeyReference else {
                throw CLIUsageError(
                    "\(command) remote S3 requires endpoint, bucket, region, access-key reference, and secret-key reference."
                )
            }
            do {
                return try StorageBackupRemoteDestination(
                    endpoint: endpoint,
                    bucket: bucket,
                    region: region,
                    objectPrefix: prefix ?? "",
                    accessKeyIDReference:
                        accessKeyReference,
                    secretAccessKeyReference:
                        secretKeyReference
                )
            } catch {
                throw CLIUsageError(
                    "\(command) remote S3 destination is invalid."
                )
            }
        }
    }

    private struct Common {
        var stateDatabasePath: String?
        var timeoutSeconds = 300
        var timeoutSelected = false
        var output: CLIOutputFormat = .text
        var outputSelected = false

        mutating func consume(
            _ arguments: [String],
            index: Int,
            command: String
        ) throws -> Int {
            switch arguments[index] {
            case "--state-db":
                stateDatabasePath = try uniqueValue(
                    arguments,
                    index: index,
                    flag: "--state-db",
                    existing: stateDatabasePath,
                    command: command
                )
                return index + 2
            case "--timeout":
                guard !timeoutSelected, index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      (1...900).contains(value) else {
                    throw CLIUsageError(
                        "\(command) --timeout must be one integer from 1 through 900."
                    )
                }
                timeoutSeconds = value
                timeoutSelected = true
                return index + 2
            case "--json":
                guard !outputSelected else {
                    throw CLIUsageError("\(command) output may be selected only once.")
                }
                output = .json
                outputSelected = true
                return index + 1
            case "--output":
                guard !outputSelected, index + 1 < arguments.count,
                      let value = CLIOutputFormat(rawValue: arguments[index + 1]) else {
                    throw CLIUsageError(
                        "\(command) --output supports only text or json and may be selected once."
                    )
                }
                output = value
                outputSelected = true
                return index + 2
            default:
                throw CLIUsageError(
                    "\(command) does not support '\(arguments[index])'."
                )
            }
        }

        func options(action: StorageCLIAction) -> StorageCLIOptions {
            StorageCLIOptions(
                action: action,
                stateDatabasePath: stateDatabasePath,
                timeoutSeconds: timeoutSeconds,
                output: output
            )
        }
    }

    private struct Confirmation {
        var dryRun = false
        var confirmation: String?

        mutating func consumeIfPresent(
            _ arguments: [String],
            index: inout Int,
            command: String
        ) throws -> Bool {
            switch arguments[index] {
            case "--dry-run":
                guard !dryRun, confirmation == nil else {
                    throw CLIUsageError(
                        "\(command) requires exactly one of --dry-run or --confirm-plan."
                    )
                }
                dryRun = true
                index += 1
                return true
            case "--confirm-plan":
                guard !dryRun, confirmation == nil,
                      index + 1 < arguments.count,
                      validSHA256(arguments[index + 1]) else {
                    throw CLIUsageError(
                        "\(command) --confirm-plan requires one exact lowercase SHA-256."
                    )
                }
                confirmation = arguments[index + 1]
                index += 2
                return true
            default:
                return false
            }
        }

        func finalize(command: String) throws -> StorageDestructiveCLIOptions {
            guard dryRun != (confirmation != nil) else {
                throw CLIUsageError(
                    "\(command) requires exactly one of --dry-run or --confirm-plan."
                )
            }
            return StorageDestructiveCLIOptions(
                dryRun: dryRun,
                confirmationPlanSHA256: confirmation
            )
        }
    }

    private static func uniqueValue(
        _ arguments: [String],
        index: Int,
        flag: String,
        existing: String?,
        command: String
    ) throws -> String {
        guard existing == nil, index + 1 < arguments.count else {
            throw CLIUsageError(
                "\(command) accepts one value after \(flag)."
            )
        }
        return arguments[index + 1]
    }

    private static func uuidValue(
        _ arguments: [String],
        index: Int,
        flag: String,
        existing: String?,
        command: String
    ) throws -> String {
        try canonicalUUID(
            uniqueValue(
                arguments,
                index: index,
                flag: flag,
                existing: existing,
                command: command
            ),
            role: flag
        )
    }

    private static func canonicalUUID(
        _ value: String,
        role: String
    ) throws -> String {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            throw CLIUsageError(
                "volume \(role) must be one canonical lowercase UUID."
            )
        }
        return value
    }

    private static func requireName(_ value: String, role: String) throws {
        guard value.utf8.count <= 128,
              value.range(
                  of: "^[A-Za-z0-9](?:[A-Za-z0-9._-]{0,127})$",
                  options: .regularExpression
              ) != nil else {
            throw CLIUsageError(
                "volume \(role) name must contain 1-128 safe characters."
            )
        }
    }

    private static func requireIdentifier(_ value: String, role: String) throws {
        guard value.utf8.count <= 256,
              value.range(
                  of: "^[A-Za-z0-9](?:[A-Za-z0-9._:/-]{0,255})$",
                  options: .regularExpression
              ) != nil else {
            throw CLIUsageError(
                "volume \(role) must contain bounded safe identifier characters."
            )
        }
    }

    private static func requireBoundedText(
        _ value: String,
        role: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw CLIUsageError(
                "volume \(role) must be non-empty bounded text without control characters."
            )
        }
    }

    private static func requireAbsoluteNormalizedPath(
        _ value: String,
        role: String
    ) throws {
        guard value.hasPrefix("/"),
              URL(fileURLWithPath: value).standardizedFileURL.path == value else {
            throw CLIUsageError(
                "volume \(role) path must be normalized and absolute."
            )
        }
    }

    private static func requireSecretReference(_ value: String) throws {
        do {
            _ = try HostwrightSecretReference.parse(value)
        } catch {
            throw CLIUsageError(
                "volume backup --key-ref requires one valid typed secret reference."
            )
        }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }
}

struct StorageCommandRunner {
    let options: StorageCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        try hostwrightWaitForAsync {
            try await runAsync()
        }
    }

    private func runAsync() async throws -> CLIRunResult {
        let provider = try await environment.storageProvider()
        let client = try StorageProviderClient(
            provider: provider,
            requestTimeoutMilliseconds:
                Int64(options.timeoutSeconds) * 1_000
        )
        let descriptor = try await client.descriptor()
        guard descriptor.providerID ==
                LocalStorageProviderContract.providerID else {
            throw diagnostic(
                .storageUnavailable,
                "Volume commands require the built-in signed hostwright-local provider."
            )
        }

        switch options.action {
        case .list(let projectID):
            let observation = try await observe(client)
            let volumes = observation.volumes.filter {
                projectID == nil || $0.projectID == projectID
            }
            return render(
                StorageVolumeListReport(
                    providerID: descriptor.providerID,
                    volumes: volumes
                ),
                text: volumeListText(volumes)
            )
        case .inspect(let volumeID):
            let volume = try await requireVolume(
                volumeID,
                client: client
            )
            return render(
                StorageVolumeInspectReport(
                    providerID: descriptor.providerID,
                    volume: volume
                ),
                text: volumeText(volume)
            )
        case .capacity:
            let observation = try await observe(client)
            let persisted = try latestCapacityStatus(
                providerID: descriptor.providerID
            )
            let report = StorageCapacityCLIReport(
                providerID: descriptor.providerID,
                totalCapacityBytes: observation.totalCapacityBytes,
                reservedCapacityBytes:
                    observation.reservedCapacityBytes,
                availableCapacityBytes:
                    observation.availableCapacityBytes,
                volumeCount: observation.volumes.count,
                latestSample: persisted?.sample,
                pressureLevel: persisted?.pressureLevel
            )
            let pressureText = persisted.map {
                """
                Pressure: \($0.pressureLevel.rawValue)
                Requested bytes: \($0.sample.requestedBytes)
                Used bytes: \($0.sample.usedBytes)
                Reclaimable bytes: \($0.sample.reclaimableBytes)
                Requested inodes: \($0.sample.requestedInodes)
                Used inodes: \($0.sample.usedInodes)
                Reclaimable inodes: \($0.sample.reclaimableInodes)
                Quota mode: \($0.sample.quotaCapability.mode.rawValue)
                """
            } ?? "Pressure: unknown"
            return render(
                report,
                text: """
                Storage capacity
                Provider: \(report.providerID)
                Total bytes: \(report.totalCapacityBytes)
                Reserved bytes: \(report.reservedCapacityBytes)
                Available bytes: \(report.availableCapacityBytes)
                Volumes: \(report.volumeCount)
                \(pressureText)

                """
            )
        case .health:
            let result: LocalStorageHealthResult =
                try await client.invoke(
                    operation: .health,
                    idempotencyKey: sha256("storage-health"),
                    payload: LocalStorageHealthPayload(),
                    result: LocalStorageHealthResult.self
                )
            return render(
                StorageHealthCLIReport(
                    providerID: descriptor.providerID,
                    health: result
                ),
                text: """
                Storage health: \(result.healthy ? "healthy" : "degraded")
                Provider: \(descriptor.providerID)
                Volumes: \(result.volumeCount)
                Pending recovery: \(result.pendingRecoveryCount)
                Issues: \(result.issues.isEmpty ? "none" : result.issues.joined(separator: ", "))

                """
            )
        case .recover(let volumeID, let idempotencyKey):
            let observation = try await observe(client)
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let repaired =
                try StorageLifecycleCoordinator
                    .repairRecoverableCreateMetadata(
                        observation: observation,
                        store: store,
                        state: state
                    )
            if repaired.contains(volumeID) {
                let evidence =
                    StorageRecoveryMetadataRepairEvidence(
                        volumeID: volumeID,
                        method: "exact-create-intent"
                    )
                return render(
                    StorageRecoveryCLIReport(
                        providerID: descriptor.providerID,
                        metadataRepair: evidence,
                        result: nil
                    ),
                    text: """
                    Storage metadata recovery: repaired
                    Volume: \(volumeID)
                    Evidence: \(evidence.method)

                    """
                )
            }
            let volume = try await requireVolume(
                volumeID,
                client: client
            )
            let result: LocalStorageRecoveryResult =
                try await client.invoke(
                    operation: .recovery,
                    mutationContext: try context(volume),
                    idempotencyKey: sha256(
                        "storage-recovery:\(volumeID):\(idempotencyKey)"
                    ),
                    payload: LocalStorageRecoveryPayload(
                        idempotencyKey: idempotencyKey
                    ),
                    result: LocalStorageRecoveryResult.self
                )
            return render(
                StorageRecoveryCLIReport(
                    providerID: descriptor.providerID,
                    metadataRepair: nil,
                    result: result
                ),
                text: """
                Storage recovery: \(result.disposition.rawValue)
                Operation: \(result.recoveredOperation.rawValue)
                Request: \(result.recoveredRequestID)

                """
            )
        case .snapshot(let action):
            return try await runSnapshot(
                action,
                client: client,
                providerID: descriptor.providerID
            )
        case .backup(let action):
            return try await runBackup(
                action,
                client: client,
                providerID: descriptor.providerID
            )
        case .delete(let volumeID, let confirmation):
            return try await StorageReclaimCommandCoordinator(
                options: options,
                environment: environment
            ).delete(
                volumeID: volumeID,
                confirmation: confirmation,
                client: client
            )
        case .prune(let confirmation):
            return try await StorageReclaimCommandCoordinator(
                options: options,
                environment: environment
            ).prune(
                confirmation: confirmation,
                client: client
            )
        }
    }

    private func runSnapshot(
        _ action: StorageSnapshotCLIAction,
        client: StorageProviderClient,
        providerID: String
    ) async throws -> CLIRunResult {
        switch action {
        case .create(let volumeID, let snapshotID, let name):
            let volume = try await requireVolume(volumeID, client: client)
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            _ = try requireStateVolume(volume, state: state)
            let plan = planSHA256(
                "snapshot-create",
                [volumeID, snapshotID, name]
            )
            let group = try acquireDataProtectionGroup(
                operation: "snapshot-create",
                resourceID: snapshotID,
                projectID: volume.projectID,
                planSHA256: plan,
                store: store
            )
            let result: LocalStorageSnapshotResult =
                try await invokeWithDataProtectionFence(
                    group,
                    store: store
                ) {
                    try await client.invoke(
                        operation: .snapshot,
                        mutationContext: try context(volume),
                        idempotencyKey: plan,
                        payload: LocalStorageSnapshotPayload(
                            snapshotID: snapshotID,
                            name: name,
                            consistency: .crashConsistent
                        ),
                        result: LocalStorageSnapshotResult.self
                    )
                }
            try persistSnapshotCreate(
                result: result,
                name: name,
                volume: volume,
                group: group,
                state: state,
                store: store
            )
            return render(
                StorageSnapshotCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage snapshot: \(result.disposition.rawValue)
                Snapshot: \(result.snapshotID)
                Source volume: \(result.sourceVolumeID)
                Consistency: \(result.consistencyClass.rawValue)
                Parent SHA-256: \(result.parentContentTreeSHA256)
                Content SHA-256: \(result.contentTreeSHA256)
                Lineage: \(result.lineage.joined(separator: ", "))

                """
            )
        case .list(let volumeID):
            let records = try storageState().loadSnapshots(
                sourceVolumeID: volumeID
            )
            return render(
                StorageStateSnapshotListReport(records: records),
                text: snapshotStateText(records)
            )
        case .inspect(let volumeID, let snapshotID):
            let records = try storageState().loadSnapshots(
                sourceVolumeID: volumeID
            )
            guard let record = records.first(where: {
                $0.id == snapshotID
            }) else {
                throw diagnostic(
                    .storageInvalid,
                    "The requested managed snapshot was not found in state."
                )
            }
            return render(
                StorageStateSnapshotInspectReport(record: record),
                text: """
                Storage snapshot
                ID: \(record.id)
                Name: \(record.name)
                Source volume: \(record.sourceVolumeID)
                State: \(record.lifecycleState.rawValue)
                Consistency: \(record.consistencyClass.rawValue)
                Parent SHA-256: \(record.parentContentTreeSHA256)
                Content SHA-256: \(record.contentTreeSHA256)
                Lineage: \(record.lineage.joined(separator: ", "))

                """
            )
        case .restore(
            let sourceVolumeID,
            let snapshotID,
            let targetVolumeID,
            let referenceID,
            let confirmation
        ):
            let plan = planSHA256(
                "snapshot-restore",
                [snapshotID, sourceVolumeID, targetVolumeID, referenceID]
            )
            if confirmation.dryRun {
                return renderPlan(
                    operation: "snapshot-restore",
                    resourceIDs: [snapshotID, targetVolumeID],
                    planSHA256: plan
                )
            }
            try requireConfirmation(confirmation, planSHA256: plan)
            let target = try await requireVolume(
                targetVolumeID,
                client: client
            )
            let result: LocalStorageRestoreResult =
                try await client.invoke(
                    operation: .restore,
                    mutationContext: try context(target),
                    idempotencyKey: plan,
                    payload: LocalStorageRestorePayload(
                        source: .snapshot,
                        sourceID: snapshotID,
                        referenceID: referenceID,
                        targets: [
                            LocalStorageRestoreTargetPayload(
                                sourceVolumeID: sourceVolumeID,
                                targetVolumeID: targetVolumeID,
                                generation: target.generation,
                                fencingToken:
                                    target.fencingToken
                            ),
                        ]
                    ),
                    result: LocalStorageRestoreResult.self
                )
            return renderRestore(result, providerID: providerID)
        case .retain(
            let volumeID,
            let snapshotID,
            let owner
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireSnapshotState(
                volumeID: volumeID,
                snapshotID: snapshotID,
                state: state
            )
            let digest = snapshotDigest(record)
            let volume = try await requireVolume(
                volumeID,
                client: client
            )
            _ = try requireStateVolume(volume, state: state)
            let plan = planSHA256(
                "snapshot-retain",
                [snapshotID, volumeID, owner, digest]
            )
            let group = try acquireDataProtectionGroup(
                operation: "snapshot-retain",
                resourceID: snapshotID,
                projectID: volume.projectID,
                planSHA256: plan,
                store: store
            )
            let result: LocalStorageSnapshotResult =
                try await invokeWithDataProtectionFence(
                    group,
                    store: store
                ) {
                    try await client.invoke(
                        operation: .snapshot,
                        mutationContext: try context(volume),
                        idempotencyKey: plan,
                        payload: LocalStorageSnapshotPayload(
                            action: .retain,
                            snapshotID: snapshotID,
                            retainerID: owner
                        ),
                        result: LocalStorageSnapshotResult.self
                    )
                }
            try persistRetentionHold(
                resourceKind: .snapshot,
                resourceID: snapshotID,
                owner: owner,
                group: group,
                state: state,
                store: store,
                verification: [
                    "contentTreeSHA256": digest,
                    "retainerID": owner,
                ]
            )
            return render(
                StorageSnapshotCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage snapshot retention: \(result.disposition.rawValue)
                Snapshot: \(result.snapshotID)
                Consistency: \(result.consistencyClass.rawValue)
                Parent SHA-256: \(result.parentContentTreeSHA256)
                Content SHA-256: \(result.contentTreeSHA256)
                Lineage: \(result.lineage.joined(separator: ", "))
                Retained by: \((result.retainedBy ?? []).joined(separator: ", "))

                """
            )
        case .export(
            let volumeID,
            let snapshotID,
            let outputPath
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireSnapshotState(
                volumeID: volumeID,
                snapshotID: snapshotID,
                state: state
            )
            let digest = snapshotDigest(record)
            let volume = try await requireVolume(
                volumeID,
                client: client
            )
            _ = try requireStateVolume(volume, state: state)
            let plan = planSHA256(
                "snapshot-export",
                [snapshotID, volumeID, digest, outputPath]
            )
            let group = try acquireDataProtectionGroup(
                operation: "snapshot-export",
                resourceID: snapshotID,
                projectID: volume.projectID,
                planSHA256: plan,
                store: store
            )
            let result: LocalStorageSnapshotResult =
                try await invokeWithDataProtectionFence(
                    group,
                    store: store
                ) {
                    try await client.invoke(
                        operation: .snapshot,
                        mutationContext: try context(volume),
                        idempotencyKey: plan,
                        payload: LocalStorageSnapshotPayload(
                            action: .export,
                            snapshotID: snapshotID,
                            destinationPath: outputPath,
                            expectedContentTreeSHA256: digest
                        ),
                        result: LocalStorageSnapshotResult.self
                    )
                }
            try finishDataProtectionGroup(
                group,
                checkpoint: "snapshot-exported",
                verification: [
                    "contentTreeSHA256": digest,
                    "destinationPath": outputPath,
                ],
                store: store
            )
            return render(
                StorageSnapshotCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage snapshot export: \(result.disposition.rawValue)
                Snapshot: \(result.snapshotID)
                Destination: \(result.exportedPath ?? outputPath)

                """
            )
        case .delete(
            let volumeID,
            let snapshotID,
            let confirmation
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireSnapshotState(
                volumeID: volumeID,
                snapshotID: snapshotID,
                state: state
            )
            let digest = snapshotDigest(record)
            let holds = try state.activeHolds(
                resourceKind: .snapshot,
                resourceID: snapshotID,
                at: hostwrightTimestamp()
            )
            guard holds.isEmpty else {
                throw diagnostic(
                    .storageConflict,
                    "The snapshot has active retention holds and cannot be deleted."
                )
            }
            let volume = try await requireVolume(
                volumeID,
                client: client
            )
            _ = try requireStateVolume(volume, state: state)
            let plan = planSHA256(
                "snapshot-delete",
                [
                    snapshotID, volumeID, digest,
                    String(record.generation),
                    record.fencingToken,
                ]
            )
            if confirmation.dryRun {
                return renderPlan(
                    operation: "snapshot-delete",
                    resourceIDs: [snapshotID],
                    planSHA256: plan
                )
            }
            try requireConfirmation(
                confirmation,
                planSHA256: plan
            )
            let group = try acquireDataProtectionGroup(
                operation: "snapshot-delete",
                resourceID: snapshotID,
                projectID: volume.projectID,
                planSHA256: plan,
                store: store
            )
            let result: LocalStorageSnapshotResult =
                try await invokeWithDataProtectionFence(
                    group,
                    store: store
                ) {
                    try await client.invoke(
                        operation: .snapshot,
                        mutationContext: try context(volume),
                        idempotencyKey: plan,
                        payload: LocalStorageSnapshotPayload(
                            action: .delete,
                            snapshotID: snapshotID,
                            expectedContentTreeSHA256: digest
                        ),
                        result: LocalStorageSnapshotResult.self
                    )
                }
            try persistSnapshotDelete(
                record: record,
                digest: digest,
                group: group,
                state: state,
                store: store
            )
            return render(
                StorageSnapshotCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage snapshot delete: \(result.disposition.rawValue)
                Snapshot: \(result.snapshotID)
                Deleted: \(result.deleted == true)

                """
            )
        }
    }

    private func runBackup(
        _ action: StorageBackupCLIAction,
        client: StorageProviderClient,
        providerID: String
    ) async throws -> CLIRunResult {
        switch action {
        case .create(
            let volumeIDs,
            let backupID,
            let name,
            let keyReference,
            let remoteDestination
        ):
            let volumes = try await volumes(
                volumeIDs,
                client: client
            )
            guard let first = volumes.first else {
                throw diagnostic(
                    .storageInvalid,
                    "Backup creation requires at least one volume."
                )
            }
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            for volume in volumes {
                _ = try requireStateVolume(volume, state: state)
            }
            let plan = planSHA256(
                "backup-create",
                [
                    backupID,
                    name,
                    sha256(keyReference),
                    try backupDestinationDigest(
                        remoteDestination
                    ),
                ] +
                    volumeIDs
            )
            let group = try acquireDataProtectionGroup(
                operation: "backup-create",
                resourceID: backupID,
                projectID: first.projectID,
                planSHA256: plan,
                store: store
            )
            let result: LocalStorageBackupResult =
                try await invokeWithDataProtectionFence(
                    group,
                    store: store
                ) {
                    try await client.invoke(
                        operation: .backup,
                        mutationContext: try context(first),
                        idempotencyKey: plan,
                        payload: LocalStorageBackupPayload(
                            backupID: backupID,
                            name: name,
                            keyReference: keyReference,
                            volumes: volumes.map {
                                LocalStorageBackupVolumePayload(
                                    volumeID: $0.volumeID,
                                    generation: $0.generation,
                                    fencingToken:
                                        $0.fencingToken
                                )
                            },
                            remoteDestination:
                                remoteDestination
                        ),
                        result: LocalStorageBackupResult.self
                    )
                }
            try persistBackupCreate(
                result: result,
                volumes: volumes,
                remoteDestination: remoteDestination,
                group: group,
                state: state,
                store: store
            )
            return render(
                StorageBackupCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage backup: \(result.disposition.rawValue)
                Backup: \(result.backupID)
                Manifest SHA-256: \(result.manifestSHA256)
                Volumes: \(result.verifiedVolumeIDs.joined(separator: ", "))

                """
            )
        case .list(let volumeID):
            let records = try storageState().loadBackups(
                volumeID: volumeID
            )
            return render(
                StorageStateBackupListReport(records: records),
                text: backupStateText(records)
            )
        case .inspect(let volumeID, let backupID):
            let records = try storageState().loadBackups(
                volumeID: volumeID
            )
            guard let record = records.first(where: {
                $0.id == backupID
            }) else {
                throw diagnostic(
                    .storageInvalid,
                    "The requested managed backup was not found in state."
                )
            }
            return render(
                StorageStateBackupInspectReport(record: record),
                text: """
                Storage backup
                ID: \(record.id)
                Volume: \(record.volumeID)
                Content SHA-256: \(record.contentSHA256)
                State: \(record.lifecycleState.rawValue)

                """
            )
        case .restore(
            let backupID,
            let keyReference,
            let targets,
            let remoteDestination,
            let confirmation
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let backupRecord = try requireBackupState(
                backupID: backupID,
                state: state
            )
            let sourceVolumeIDs = try backupVolumeIDs(
                backupRecord,
                store: store
            )
            guard Set(sourceVolumeIDs) ==
                    Set(targets.map(\.sourceVolumeID)),
                  validSHA256(backupRecord.contentSHA256) else {
                throw diagnostic(
                    .storageConflict,
                    "Backup restore targets do not match the authoritative verified source-volume set."
                )
            }
            try requireBackupDestination(
                remoteDestination,
                record: backupRecord
            )
            let expectedManifestSHA256 =
                backupRecord.contentSHA256
            let plan = planSHA256(
                "backup-restore",
                [
                    backupID,
                    expectedManifestSHA256,
                    sha256(keyReference),
                    try backupDestinationDigest(
                        remoteDestination
                    ),
                ] +
                    targets.flatMap {
                        [$0.sourceVolumeID, $0.targetVolumeID]
                    }
            )
            if confirmation.dryRun {
                return renderPlan(
                    operation: "backup-restore",
                    resourceIDs:
                        [backupID] + targets.map(\.targetVolumeID),
                    planSHA256: plan
                )
            }
            try requireConfirmation(confirmation, planSHA256: plan)
            let observedTargets = try await volumes(
                targets.map(\.targetVolumeID),
                client: client
            )
            let byID = Dictionary(
                uniqueKeysWithValues: observedTargets.map {
                    ($0.volumeID, $0)
                }
            )
            guard let first = observedTargets.first else {
                throw diagnostic(
                    .storageInvalid,
                    "Backup restoration requires at least one target."
                )
            }
            let result: LocalStorageRestoreResult =
                try await client.invoke(
                    operation: .restore,
                    mutationContext: try context(first),
                    idempotencyKey: plan,
                    payload: LocalStorageRestorePayload(
                        source: .backup,
                        sourceID: backupID,
                        expectedManifestSHA256:
                            expectedManifestSHA256,
                        keyReference: keyReference,
                        targets: try targets.map {
                            guard let observed = byID[
                                $0.targetVolumeID
                            ] else {
                                throw diagnostic(
                                    .storageConflict,
                                    "A backup restore target disappeared during observation."
                                )
                            }
                            return LocalStorageRestoreTargetPayload(
                                sourceVolumeID:
                                    $0.sourceVolumeID,
                                targetVolumeID:
                                    $0.targetVolumeID,
                                generation: observed.generation,
                                fencingToken:
                                    observed.fencingToken
                            )
                        },
                        remoteDestination:
                            remoteDestination
                    ),
                    result: LocalStorageRestoreResult.self
                )
            return renderRestore(result, providerID: providerID)
        case .verify(
            let volumeID,
            let backupID,
            let keyReference,
            let remoteDestination
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireBackupState(
                volumeID: volumeID,
                backupID: backupID,
                state: state
            )
            let volumes = try await backupVolumes(
                record,
                client: client,
                state: state,
                store: store
            )
            try requireBackupDestination(
                remoteDestination,
                record: record
            )
            let plan = planSHA256(
                "backup-verify",
                [
                    backupID, record.contentSHA256,
                    sha256(keyReference),
                    try backupDestinationDigest(
                        remoteDestination
                    ),
                ] + volumes.map(\.volumeID)
            )
            let group = try acquireDataProtectionGroup(
                operation: "backup-verify",
                resourceID: backupID,
                projectID: volumes[0].projectID,
                planSHA256: plan,
                store: store
            )
            let result = try await invokeWithDataProtectionFence(
                group,
                store: store
            ) {
                try await invokeBackupAction(
                    .verify,
                    backupID: backupID,
                    keyReference: keyReference,
                    owner: nil,
                    expectedManifestSHA256:
                        record.contentSHA256,
                    remoteDestination:
                        remoteDestination,
                    volumes: volumes,
                    planSHA256: plan,
                    client: client
                )
            }
            try finishDataProtectionGroup(
                group,
                checkpoint: "backup-verified",
                verification: [
                    "manifestSHA256":
                        result.manifestSHA256,
                    "verifiedVolumeIDs":
                        result.verifiedVolumeIDs,
                ],
                store: store
            )
            return render(
                StorageBackupCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage backup verification: \(result.disposition.rawValue)
                Backup: \(result.backupID)
                Manifest SHA-256: \(result.manifestSHA256)

                """
            )
        case .retain(
            let volumeID,
            let backupID,
            let owner,
            let remoteDestination
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireBackupState(
                volumeID: volumeID,
                backupID: backupID,
                state: state
            )
            let volumes = try await backupVolumes(
                record,
                client: client,
                state: state,
                store: store
            )
            try requireBackupDestination(
                remoteDestination,
                record: record
            )
            let plan = planSHA256(
                "backup-retain",
                [
                    backupID,
                    record.contentSHA256,
                    owner,
                    try backupDestinationDigest(
                        remoteDestination
                    ),
                ] +
                    volumes.map(\.volumeID)
            )
            let group = try acquireDataProtectionGroup(
                operation: "backup-retain",
                resourceID: backupID,
                projectID: volumes[0].projectID,
                planSHA256: plan,
                store: store
            )
            let result = try await invokeWithDataProtectionFence(
                group,
                store: store
            ) {
                try await invokeBackupAction(
                    .retain,
                    backupID: backupID,
                    keyReference: nil,
                    owner: owner,
                    expectedManifestSHA256:
                        record.contentSHA256,
                    remoteDestination:
                        remoteDestination,
                    volumes: volumes,
                    planSHA256: plan,
                    client: client
                )
            }
            try persistRetentionHold(
                resourceKind: .backup,
                resourceID: backupID,
                owner: owner,
                group: group,
                state: state,
                store: store,
                verification: [
                    "manifestSHA256":
                        result.manifestSHA256,
                    "retainerID": owner,
                ]
            )
            return render(
                StorageBackupCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage backup retention: \(result.disposition.rawValue)
                Backup: \(result.backupID)
                Retained by: \((result.retainedBy ?? []).joined(separator: ", "))

                """
            )
        case .delete(
            let volumeID,
            let backupID,
            let remoteDestination,
            let confirmation
        ):
            let store = try storageStore()
            let state = StorageStateRepository(store: store)
            let record = try requireBackupState(
                volumeID: volumeID,
                backupID: backupID,
                state: state
            )
            let holds = try state.activeHolds(
                resourceKind: .backup,
                resourceID: backupID,
                at: hostwrightTimestamp()
            )
            guard holds.isEmpty else {
                throw diagnostic(
                    .storageConflict,
                    "The backup has active retention holds and cannot be deleted."
                )
            }
            let volumes = try await backupVolumes(
                record,
                client: client,
                state: state,
                store: store
            )
            try requireBackupDestination(
                remoteDestination,
                record: record
            )
            let plan = planSHA256(
                "backup-delete",
                [
                    backupID, record.contentSHA256,
                    String(record.generation),
                    record.fencingToken,
                    try backupDestinationDigest(
                        remoteDestination
                    ),
                ] + volumes.map(\.volumeID)
            )
            if confirmation.dryRun {
                return renderPlan(
                    operation: "backup-delete",
                    resourceIDs: [backupID],
                    planSHA256: plan
                )
            }
            try requireConfirmation(
                confirmation,
                planSHA256: plan
            )
            let group = try acquireDataProtectionGroup(
                operation: "backup-delete",
                resourceID: backupID,
                projectID: volumes[0].projectID,
                planSHA256: plan,
                store: store
            )
            let result = try await invokeWithDataProtectionFence(
                group,
                store: store
            ) {
                try await invokeBackupAction(
                    .delete,
                    backupID: backupID,
                    keyReference: nil,
                    owner: nil,
                    expectedManifestSHA256:
                        record.contentSHA256,
                    remoteDestination:
                        remoteDestination,
                    volumes: volumes,
                    planSHA256: plan,
                    client: client
                )
            }
            try persistBackupDelete(
                record: record,
                group: group,
                state: state,
                store: store
            )
            return render(
                StorageBackupCLIReport(
                    providerID: providerID,
                    result: result
                ),
                text: """
                Storage backup delete: \(result.disposition.rawValue)
                Backup: \(result.backupID)
                Deleted: \(result.deleted == true)

                """
            )
        }
    }

    private func storageStore() throws -> SQLiteStateStore {
        let configuration = try hostwrightStateStoreConfiguration(
            explicitPath: options.stateDatabasePath,
            environment: environment
        )
        let store = SQLiteStateStore(configuration: configuration)
        try store.migrate()
        return store
    }

    private func storageState() throws -> StorageStateRepository {
        StorageStateRepository(store: try storageStore())
    }

    private func latestCapacityStatus(
        providerID: String
    ) throws -> StorageStateCapacitySampleRecord? {
        let configuration = try hostwrightStateStoreConfiguration(
            explicitPath: options.stateDatabasePath,
            environment: environment
        )
        guard environment.fileExists(
            configuration.databasePath
        ) else {
            return nil
        }
        let store = SQLiteStateStore(configuration: configuration)
        guard try store.schemaVersion() ==
                HostwrightContractVersions.stateSchema else {
            throw diagnostic(
                .stateStoreUnavailable,
                "Storage capacity status requires the current schema-v15 state."
            )
        }
        return try StorageStateRepository(store: store)
            .latestCapacitySample(
                providerID: providerID,
                topologyNodeID:
                    StorageLifecycleCoordinator.topologyNodeID
            )
    }

    private func requireStateVolume(
        _ observed: LocalStorageVolumeObservation,
        state: StorageStateRepository
    ) throws -> StorageStateVolumeRecord {
        guard let record = try state.loadVolume(
            id: observed.volumeID
        ),
        record.providerID == observed.providerID,
        record.providerVolumeID == observed.volumeID,
        record.generation == Int64(observed.generation),
        record.fencingToken == observed.fencingToken,
        record.lifecycleState == .available else {
            throw diagnostic(
                .storageConflict,
                "Provider volume ownership does not match authoritative schema-v15 state."
            )
        }
        return record
    }

    private func requireSnapshotState(
        volumeID: String,
        snapshotID: String,
        state: StorageStateRepository
    ) throws -> StorageStateSnapshotRecord {
        guard let record = try state.loadSnapshots(
            sourceVolumeID: volumeID
        ).first(where: {
            $0.id == snapshotID &&
                $0.providerSnapshotID == snapshotID &&
                $0.lifecycleState == .ready
        }) else {
            throw diagnostic(
                .storageInvalid,
                "The requested ready managed snapshot was not found in state."
            )
        }
        return record
    }

    private func requireBackupState(
        volumeID: String,
        backupID: String,
        state: StorageStateRepository
    ) throws -> StorageStateBackupRecord {
        guard let record = try state.loadBackups(
            volumeID: volumeID
        ).first(where: {
            $0.id == backupID &&
                $0.lifecycleState == .ready
        }) else {
            throw diagnostic(
                .storageInvalid,
                "The requested ready managed backup was not found in state."
            )
        }
        return record
    }

    private func requireBackupState(
        backupID: String,
        state: StorageStateRepository
    ) throws -> StorageStateBackupRecord {
        guard let record = try state.loadBackup(id: backupID),
              record.lifecycleState == .ready else {
            throw diagnostic(
                .storageInvalid,
                "The requested ready managed backup was not found in state."
            )
        }
        return record
    }

    private func snapshotDigest(
        _ record: StorageStateSnapshotRecord
    ) -> String {
        record.contentTreeSHA256
    }

    private func backupVolumes(
        _ record: StorageStateBackupRecord,
        client: StorageProviderClient,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) async throws -> [LocalStorageVolumeObservation] {
        let volumeIDs = try backupVolumeIDs(
            record,
            store: store
        )
        let observed = try await volumes(
            volumeIDs,
            client: client
        )
        for volume in observed {
            _ = try requireStateVolume(volume, state: state)
        }
        return observed
    }

    private func backupVolumeIDs(
        _ record: StorageStateBackupRecord,
        store: SQLiteStateStore
    ) throws -> [String] {
        guard let group = try store.operationGroups.load(
            id: record.operationGroupID
        ),
        let object = try jsonObject(
            group.verificationJSONRedacted
        ),
        let volumeIDs = object["verifiedVolumeIDs"] as? [String],
        !volumeIDs.isEmpty,
        volumeIDs.allSatisfy(validCanonicalUUID) else {
            throw diagnostic(
                .storageConflict,
                "Backup state is missing exact verified source-volume identities."
            )
        }
        return volumeIDs.sorted()
    }

    private func persistSnapshotCreate(
        result: LocalStorageSnapshotResult,
        name: String,
        volume: LocalStorageVolumeObservation,
        group: OperationGroupRecord,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws {
        if let existing = try state.loadSnapshots(
            sourceVolumeID: volume.volumeID
        ).first(where: { $0.id == result.snapshotID }) {
            let digestMatches: Bool
            if group.status == .succeeded {
                digestMatches =
                    snapshotDigest(existing) ==
                        result.contentTreeSHA256
            } else {
                digestMatches =
                    existing.operationGroupID == group.id &&
                    existing.fencingToken ==
                        group.fencingToken
            }
            guard existing.name == name,
                  existing.providerID == volume.providerID,
                  existing.providerSnapshotID ==
                    result.snapshotID,
                  existing.lifecycleState == .ready,
                  existing.consistencyClass ==
                    result.consistencyClass,
                  existing.parentContentTreeSHA256 ==
                    result.parentContentTreeSHA256,
                  existing.contentTreeSHA256 ==
                    result.contentTreeSHA256,
                  existing.lineage == result.lineage,
                  digestMatches else {
                throw diagnostic(
                    .storageConflict,
                    "Existing snapshot state conflicts with provider verification."
                )
            }
        } else {
            let timestamp = hostwrightTimestamp()
            try state.saveSnapshot(
                StorageStateSnapshotRecord(
                    id: result.snapshotID,
                    name: name,
                    sourceVolumeID: volume.volumeID,
                    providerID: volume.providerID,
                    providerSnapshotID: result.snapshotID,
                    consistencyClass:
                        result.consistencyClass,
                    parentContentTreeSHA256:
                        result.parentContentTreeSHA256,
                    contentTreeSHA256:
                        result.contentTreeSHA256,
                    lineage: result.lineage,
                    generation: 1,
                    fencingToken: group.fencingToken,
                    sizeBytes: volume.capacityBytes,
                    lifecycleState: .ready,
                    operationGroupID: group.id,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
        }
        try finishDataProtectionGroup(
            group,
            checkpoint: "snapshot-ready",
            verification: [
                "contentTreeSHA256":
                    result.contentTreeSHA256,
                "consistencyClass":
                    result.consistencyClass.rawValue,
                "parentContentTreeSHA256":
                    result.parentContentTreeSHA256,
                "lineage": result.lineage,
                "sourceVolumeID": result.sourceVolumeID,
            ],
            store: store
        )
    }

    private func persistSnapshotDelete(
        record: StorageStateSnapshotRecord,
        digest: String,
        group: OperationGroupRecord,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws {
        try state.saveSnapshot(
            StorageStateSnapshotRecord(
                id: record.id,
                name: record.name,
                sourceVolumeID: record.sourceVolumeID,
                providerID: record.providerID,
                providerSnapshotID:
                    record.providerSnapshotID,
                consistencyClass: record.consistencyClass,
                parentContentTreeSHA256:
                    record.parentContentTreeSHA256,
                contentTreeSHA256: record.contentTreeSHA256,
                lineage: record.lineage,
                generation: record.generation + 1,
                fencingToken: group.fencingToken,
                sizeBytes: record.sizeBytes,
                lifecycleState: .deleted,
                operationGroupID: group.id,
                createdAt: record.createdAt,
                updatedAt: hostwrightTimestamp()
            ),
            replacing: StorageStateExpectedVersion(
                generation: record.generation,
                fencingToken: record.fencingToken
            )
        )
        try finishDataProtectionGroup(
            group,
            checkpoint: "snapshot-deleted",
            verification: [
                "contentTreeSHA256": digest,
                "deleted": true,
            ],
            store: store
        )
    }

    private func persistBackupCreate(
        result: LocalStorageBackupResult,
        volumes: [LocalStorageVolumeObservation],
        remoteDestination:
            StorageBackupRemoteDestination?,
        group: OperationGroupRecord,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws {
        guard let first = volumes.first else {
            throw diagnostic(
                .storageInvalid,
                "Backup state requires one source volume."
            )
        }
        if let existing = try state.loadBackups(
            volumeID: first.volumeID
        ).first(where: { $0.id == result.backupID }) {
            guard existing.contentSHA256 ==
                    result.manifestSHA256,
                  existing.lifecycleState == .ready else {
                throw diagnostic(
                    .storageConflict,
                    "Existing backup state conflicts with provider verification."
                )
            }
        } else {
            let timestamp = hostwrightTimestamp()
            let sizeBytes = volumes.reduce(Int64(0)) {
                partial, volume in
                let (sum, overflow) =
                    partial.addingReportingOverflow(
                        volume.capacityBytes
                    )
                return overflow ? Int64.max : sum
            }
            try state.saveBackup(
                StorageStateBackupRecord(
                    id: result.backupID,
                    volumeID: first.volumeID,
                    snapshotID: nil,
                    destinationRedacted:
                        remoteDestination?
                            .redactedDescription ??
                            "hostwright-local://[REDACTED]",
                    contentSHA256: result.manifestSHA256,
                    sizeBytes: sizeBytes,
                    generation: 1,
                    fencingToken: group.fencingToken,
                    lifecycleState: .ready,
                    operationGroupID: group.id,
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
        }
        try finishDataProtectionGroup(
            group,
            checkpoint: "backup-ready",
            verification: [
                "manifestSHA256": result.manifestSHA256,
                "verifiedVolumeIDs":
                    result.verifiedVolumeIDs,
            ],
            store: store
        )
    }

    private func persistBackupDelete(
        record: StorageStateBackupRecord,
        group: OperationGroupRecord,
        state: StorageStateRepository,
        store: SQLiteStateStore
    ) throws {
        try state.saveBackup(
            StorageStateBackupRecord(
                id: record.id,
                volumeID: record.volumeID,
                snapshotID: record.snapshotID,
                destinationRedacted:
                    record.destinationRedacted,
                contentSHA256: record.contentSHA256,
                sizeBytes: record.sizeBytes,
                generation: record.generation + 1,
                fencingToken: group.fencingToken,
                lifecycleState: .deleted,
                operationGroupID: group.id,
                createdAt: record.createdAt,
                updatedAt: hostwrightTimestamp()
            ),
            replacing: StorageStateExpectedVersion(
                generation: record.generation,
                fencingToken: record.fencingToken
            )
        )
        try finishDataProtectionGroup(
            group,
            checkpoint: "backup-deleted",
            verification: [
                "manifestSHA256": record.contentSHA256,
                "deleted": true,
            ],
            store: store
        )
    }

    private func persistRetentionHold(
        resourceKind: StorageHoldResourceKind,
        resourceID: String,
        owner: String,
        group: OperationGroupRecord,
        state: StorageStateRepository,
        store: SQLiteStateStore,
        verification: [String: Any]
    ) throws {
        let timestamp = hostwrightTimestamp()
        let existing = try state.activeHolds(
            resourceKind: resourceKind,
            resourceID: resourceID,
            at: timestamp
        ).first {
            $0.reasonRedacted == "retained-by:\(owner)"
        }
        if existing == nil {
            try state.saveHold(
                StorageStateHoldRecord(
                    id: HostwrightResourceUUID.legacy(
                        kind: "storage-retention-hold",
                        identifier:
                            "\(resourceKind.rawValue):\(resourceID):\(owner)"
                    ),
                    resourceKind: resourceKind,
                    resourceID: resourceID,
                    reasonRedacted: "retained-by:\(owner)",
                    generation: 1,
                    fencingToken: group.fencingToken,
                    operationGroupID: group.id,
                    createdAt: timestamp,
                    expiresAt: nil,
                    releasedAt: nil
                )
            )
        }
        try finishDataProtectionGroup(
            group,
            checkpoint: "\(resourceKind.rawValue)-retained",
            verification: verification,
            store: store
        )
    }

    private func invokeBackupAction(
        _ action: LocalStorageBackupAction,
        backupID: String,
        keyReference: String?,
        owner: String?,
        expectedManifestSHA256: String,
        remoteDestination:
            StorageBackupRemoteDestination?,
        volumes: [LocalStorageVolumeObservation],
        planSHA256: String,
        client: StorageProviderClient
    ) async throws -> LocalStorageBackupResult {
        guard let first = volumes.first else {
            throw diagnostic(
                .storageInvalid,
                "Backup operation requires one verified source volume."
            )
        }
        return try await client.invoke(
            operation: .backup,
            mutationContext: try context(first),
            idempotencyKey: planSHA256,
            payload: LocalStorageBackupPayload(
                action: action,
                backupID: backupID,
                keyReference: keyReference,
                volumes: volumes.map {
                    LocalStorageBackupVolumePayload(
                        volumeID: $0.volumeID,
                        generation: $0.generation,
                        fencingToken: $0.fencingToken
                    )
                },
                retainerID: owner,
                expectedManifestSHA256:
                    expectedManifestSHA256,
                remoteDestination:
                    remoteDestination
            ),
            result: LocalStorageBackupResult.self
        )
    }

    private func backupDestinationDigest(
        _ destination: StorageBackupRemoteDestination?
    ) throws -> String {
        try destination?.canonicalSHA256() ??
            "hostwright-local"
    }

    private func requireBackupDestination(
        _ destination: StorageBackupRemoteDestination?,
        record: StorageStateBackupRecord
    ) throws {
        let expected =
            destination?.redactedDescription ??
            "hostwright-local://[REDACTED]"
        guard expected == record.destinationRedacted else {
            throw diagnostic(
                .storageConflict,
                "The requested backup destination does not match authoritative state."
            )
        }
    }

    private func acquireDataProtectionGroup(
        operation: String,
        resourceID: String,
        projectID: String,
        planSHA256: String,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let id = HostwrightResourceUUID.legacy(
            kind: "storage-data-protection-operation",
            identifier: "\(operation):\(resourceID):\(planSHA256)"
        )
        let fence = HostwrightResourceUUID.legacy(
            kind: "storage-data-protection-fence",
            identifier: id
        )
        let timestamp = hostwrightTimestamp()
        let candidate = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "storage-data-protection",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: operation,
            status: .active,
            groupIdempotencyKey:
                "storage-data-protection:\(planSHA256)",
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-cli",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: options.timeoutSeconds,
                to: timestamp
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "Re-observe exact provider and schema-v15 state before retry.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: try json([
                "operation": operation,
                "resourceID": resourceID,
            ]),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        if let existing = try store.operationGroups.load(id: id) {
            guard existing.planHash == planSHA256,
                  existing.fencingToken == fence else {
                throw diagnostic(
                    .storageConflict,
                    "Existing data-protection operation has different authority."
                )
            }
            switch existing.status {
            case .active, .succeeded:
                return existing
            case .interrupted:
                return try store.operationGroups.resumeInterrupted(
                    groupID: id,
                    expectedFencingToken: fence,
                    lockOwner: "hostwright-cli",
                    lockExpiresAt: candidate.lockExpiresAt,
                    updatedAt: timestamp
                )
            case .failed:
                throw diagnostic(
                    .storageConflict,
                    "A failed data-protection operation requires explicit recovery."
                )
            }
        }
        let acquired = try store.operationGroups.acquire(
            candidate,
            currentTimestamp: timestamp
        )
        guard let group = acquired.acquired else {
            throw diagnostic(
                .storageConflict,
                "Another storage mutation owns the project fence."
            )
        }
        return group
    }

    private func finishDataProtectionGroup(
        _ group: OperationGroupRecord,
        checkpoint: String,
        verification: [String: Any],
        store: SQLiteStateStore
    ) throws {
        if group.status == .succeeded {
            return
        }
        let timestamp = hostwrightTimestamp()
        let payload = try json(verification)
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: checkpoint,
            verificationJSONRedacted: payload,
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: "",
            updatedAt: timestamp,
            metadataJSONRedacted: "{}"
        )
    }

    private func invokeWithDataProtectionFence<Result>(
        _ group: OperationGroupRecord,
        store: SQLiteStateStore,
        operation: () async throws -> Result
    ) async throws -> Result {
        do {
            return try await operation()
        } catch {
            try? store.operationGroups.finish(
                groupID: group.id,
                status: .interrupted,
                checkpoint: "recovery-required",
                manualRecoveryHintRedacted:
                    "Re-observe the exact provider resource before retrying.",
                updatedAt: hostwrightTimestamp(),
                metadataJSONRedacted:
                    #"{"result":"interrupted"}"#
            )
            throw error
        }
    }

    private func json(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw diagnostic(
                .storageInvalid,
                "Storage operation evidence is not valid JSON."
            )
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(
        _ text: String
    ) throws -> [String: Any]? {
        guard let data = text.data(using: .utf8) else {
            return nil
        }
        return try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
    }

    private func validCanonicalUUID(_ value: String) -> Bool {
        value == value.lowercased() &&
            UUID(uuidString: value)?.uuidString.lowercased() ==
                value
    }

    private func validSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains($0) ||
                ("a"..."f").contains($0)
        }
    }

    private func observe(
        _ client: StorageProviderClient
    ) async throws -> LocalStorageObservation {
        try await client.invoke(
            operation: .observe,
            idempotencyKey: sha256("volume-command-observe"),
            payload: LocalStorageObservePayload(),
            result: LocalStorageObservation.self
        )
    }

    private func requireVolume(
        _ volumeID: String,
        client: StorageProviderClient
    ) async throws -> LocalStorageVolumeObservation {
        let observation: LocalStorageObservation =
            try await client.invoke(
                operation: .observe,
                idempotencyKey: sha256(
                    "volume-command-observe:\(volumeID)"
                ),
                payload: LocalStorageObservePayload(
                    volumeID: volumeID
                ),
                result: LocalStorageObservation.self
            )
        guard observation.unmanagedEntries.isEmpty,
              observation.ambiguousVolumeIDs.isEmpty,
              let volume = observation.volumes.first(where: {
                  $0.volumeID == volumeID
              }) else {
            throw diagnostic(
                .storageConflict,
                "The requested volume is missing, unmanaged, or ambiguous."
            )
        }
        return volume
    }

    private func volumes(
        _ volumeIDs: [String],
        client: StorageProviderClient
    ) async throws -> [LocalStorageVolumeObservation] {
        var result: [LocalStorageVolumeObservation] = []
        for volumeID in volumeIDs.sorted() {
            result.append(
                try await requireVolume(volumeID, client: client)
            )
        }
        guard Set(result.map(\.projectID)).count == 1,
              Set(result.map(\.projectGeneration)).count == 1 else {
            throw diagnostic(
                .storageConflict,
                "One storage operation cannot cross project authority."
            )
        }
        return result
    }

    private func context(
        _ volume: LocalStorageVolumeObservation
    ) throws -> StorageProviderMutationContext {
        guard let projectUUID = UUID(uuidString: volume.projectID),
              let volumeUUID = UUID(uuidString: volume.volumeID),
              let fencingToken = UUID(
                  uuidString: volume.fencingToken
              ) else {
            throw diagnostic(
                .storageConflict,
                "The storage provider returned non-canonical ownership authority."
            )
        }
        return StorageProviderMutationContext(
            projectUUID: projectUUID,
            projectGeneration: volume.projectGeneration,
            resourceUUID: volumeUUID,
            resourceGeneration: volume.generation,
            fencingToken: fencingToken
        )
    }

    private func requireConfirmation(
        _ confirmation: StorageDestructiveCLIOptions,
        planSHA256: String
    ) throws {
        guard confirmation.confirmationPlanSHA256 == planSHA256 else {
            throw diagnostic(
                .storageConflict,
                "The exact storage plan changed; run the dry-run again."
            )
        }
    }

    private func planSHA256(
        _ operation: String,
        _ values: [String]
    ) -> String {
        sha256(
            (["hostwright.storage.command-plan.v1", operation] + values)
                .joined(separator: "\n")
        )
    }

    private func renderPlan(
        operation: String,
        resourceIDs: [String],
        planSHA256: String
    ) -> CLIRunResult {
        render(
            StorageDestructivePlanReport(
                operation: operation,
                resourceIDs: resourceIDs,
                planSHA256: planSHA256
            ),
            text: """
            Storage \(operation) plan
            Resources: \(resourceIDs.isEmpty ? "none" : resourceIDs.joined(separator: ", "))
            Confirm with: --confirm-plan \(planSHA256)

            """
        )
    }

    private func renderRestore(
        _ result: LocalStorageRestoreResult,
        providerID: String
    ) -> CLIRunResult {
        render(
            StorageRestoreCLIReport(
                providerID: providerID,
                result: result
            ),
            text: """
            Storage restore: \(result.disposition.rawValue)
            Source: \(result.source.rawValue) \(result.sourceID)
            Targets: \(result.restoredTargetVolumeIDs.joined(separator: ", "))

            """
        )
    }

    private func render<T: Encodable>(
        _ report: T,
        text: String
    ) -> CLIRunResult {
        CLIRunResult(
            standardOutput:
                options.output == .json
                    ? CLIJSON.codable(report)
                    : text
        )
    }

    private func volumeListText(
        _ volumes: [LocalStorageVolumeObservation]
    ) -> String {
        var lines = ["Hostwright managed volumes"]
        if volumes.isEmpty {
            lines.append("- none")
        } else {
            lines += volumes.map {
                "- \($0.volumeID) \($0.name) \($0.capacityBytes) bytes"
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func volumeText(
        _ volume: LocalStorageVolumeObservation
    ) -> String {
        """
        Hostwright managed volume
        ID: \(volume.volumeID)
        Name: \(volume.name)
        Project: \(volume.projectID)
        Generation: \(volume.generation)
        Capacity bytes: \(volume.capacityBytes)
        Attachments: \(volume.attachments.count)

        """
    }

    private func snapshotStateText(
        _ records: [StorageStateSnapshotRecord]
    ) -> String {
        var lines = ["Hostwright managed snapshots"]
        lines += records.isEmpty
            ? ["- none"]
            : records.map {
                "- \($0.id) \($0.name) \($0.lifecycleState.rawValue) " +
                    "\($0.consistencyClass.rawValue) " +
                    "parent=\($0.parentContentTreeSHA256) " +
                    "content=\($0.contentTreeSHA256) " +
                    "lineage=\($0.lineage.joined(separator: ","))"
            }
        return lines.joined(separator: "\n") + "\n"
    }

    private func backupStateText(
        _ records: [StorageStateBackupRecord]
    ) -> String {
        var lines = ["Hostwright managed backups"]
        lines += records.isEmpty
            ? ["- none"]
            : records.map { "- \($0.id) \($0.lifecycleState.rawValue)" }
        return lines.joined(separator: "\n") + "\n"
    }

    private func diagnostic(
        _ code: HostwrightErrorCode,
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(code: code, message: message)
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct StorageVolumeListReport: Encodable {
    let schemaVersion = 1
    let kind = "storageVolumeList"
    let providerID: String
    let volumes: [LocalStorageVolumeObservation]
}

private struct StorageVolumeInspectReport: Encodable {
    let schemaVersion = 1
    let kind = "storageVolumeInspect"
    let providerID: String
    let volume: LocalStorageVolumeObservation
}

private struct StorageCapacityCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageCapacity"
    let providerID: String
    let totalCapacityBytes: Int64
    let reservedCapacityBytes: Int64
    let availableCapacityBytes: Int64
    let volumeCount: Int
    let latestSample: StorageCapacitySample?
    let pressureLevel: StoragePressureLevel?
}

private struct StorageHealthCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageHealth"
    let providerID: String
    let health: LocalStorageHealthResult
}

private struct StorageRecoveryCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageRecovery"
    let providerID: String
    let metadataRepair: StorageRecoveryMetadataRepairEvidence?
    let result: LocalStorageRecoveryResult?
}

private struct StorageRecoveryMetadataRepairEvidence: Encodable {
    let volumeID: String
    let method: String
}

private struct StorageSnapshotCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageSnapshot"
    let providerID: String
    let result: LocalStorageSnapshotResult
}

private struct StorageBackupCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageBackup"
    let providerID: String
    let result: LocalStorageBackupResult
}

private struct StorageRestoreCLIReport: Encodable {
    let schemaVersion = 1
    let kind = "storageRestore"
    let providerID: String
    let result: LocalStorageRestoreResult
}

private struct StorageStateSnapshotListReport: Encodable {
    let schemaVersion = 1
    let kind = "storageSnapshotList"
    let records: [StorageStateSnapshotRecord]
}

private struct StorageStateSnapshotInspectReport: Encodable {
    let schemaVersion = 1
    let kind = "storageSnapshotInspect"
    let record: StorageStateSnapshotRecord
}

private struct StorageStateBackupListReport: Encodable {
    let schemaVersion = 1
    let kind = "storageBackupList"
    let records: [StorageStateBackupRecord]
}

private struct StorageStateBackupInspectReport: Encodable {
    let schemaVersion = 1
    let kind = "storageBackupInspect"
    let record: StorageStateBackupRecord
}

private struct StorageDestructivePlanReport: Encodable {
    let schemaVersion = 1
    let kind = "storageDestructivePlan"
    let operation: String
    let resourceIDs: [String]
    let planSHA256: String
}
