import Foundation
import HostwrightObservability

public struct StateSupportBundleStatus: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let pendingRecovery: Bool
    public let pendingPhase: String?
    public let retainedCreationReceipts: Int
    public let automaticUpload: Bool

    public init(pendingRecovery: Bool, pendingPhase: String?, retainedCreationReceipts: Int) {
        self.schemaVersion = 1
        self.kind = "hostwright.support-bundle.status"
        self.pendingRecovery = pendingRecovery
        self.pendingPhase = pendingPhase
        self.retainedCreationReceipts = retainedCreationReceipts
        self.automaticUpload = false
    }
}

public struct StateSupportBundleRecoveryResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let action: String
    public let bundleID: String?
    public let safeHold: Bool

    public init(action: String, bundleID: String?, safeHold: Bool) {
        self.schemaVersion = 1
        self.kind = "hostwright.support-bundle.recovery"
        self.action = action
        self.bundleID = bundleID
        self.safeHold = safeHold
    }
}

public struct StateSupportBundleEvidenceService: Sendable {
    private let store: SQLiteStateStore
    private let paths: StateMaintenancePaths
    private let date: @Sendable () -> Date

    private var journalPath: String { paths.journalPath + ".support-bundle-v1" }

    public init(store: SQLiteStateStore, date: @escaping @Sendable () -> Date = Date.init) throws {
        self.store = store
        self.paths = try store.configuration.maintenancePaths()
        self.date = date
    }

    public func status() throws -> StateSupportBundleStatus {
        let journal = StateMaintenanceFileSupport.exists(journalPath) ? try readJournal() : nil
        let count = try store.withValidatedConnection(readOnly: true) { connection in
            let value = try connection.query(
                """
                SELECT COUNT(*) FROM event_ledger
                WHERE type = ? AND source = ?
                """,
                bindings: [
                    .text(HostwrightSupportBundleContract.createdEventType),
                    .text(HostwrightSupportBundleContract.source)
                ]
            ).first?.first ?? nil
            return Int(value ?? "") ?? 0
        }
        return StateSupportBundleStatus(
            pendingRecovery: journal != nil,
            pendingPhase: journal?.phase.rawValue,
            retainedCreationReceipts: count
        )
    }

    public func beginCreation(
        bundleID: String,
        previewSHA256: String,
        outputPath: String,
        encrypted: Bool,
        recipientReferenceSHA256: String?
    ) throws -> String {
        guard !StateMaintenanceFileSupport.exists(journalPath) else {
            throw HostwrightSupportBundleError.recoveryRequired
        }
        let operationID = UUID().uuidString.lowercased()
        let journal = StateSupportBundleJournal(
            operationID: operationID,
            action: .create,
            phase: .creationPrepared,
            bundleID: bundleID,
            previewSHA256: previewSHA256,
            outputPath: outputPath,
            outputPathSHA256: pathSHA256(outputPath),
            encrypted: encrypted,
            recipientReferenceSHA256: recipientReferenceSHA256,
            fileIdentity: nil,
            preparedAt: timestamp(),
            updatedAt: timestamp()
        )
        try validate(journal)
        try SecureStatePathManager().writePrivateJSON(journal, to: journalPath)
        return operationID
    }

    public func recordCreatedFile(
        operationID: String,
        identity: HostwrightSupportBundleFileIdentity
    ) throws {
        let journal = try matchingJournal(operationID, action: .create, phase: .creationPrepared)
        let updated = journal.replacing(phase: .creationOutputWritten, fileIdentity: identity, updatedAt: timestamp())
        try validate(updated)
        try SecureStatePathManager().replacePrivateJSON(updated, at: journalPath)
    }

    public func completeCreation(operationID: String) throws -> StateSupportBundleCreatedEvidence {
        let journal = try matchingJournal(operationID, action: .create, phase: .creationOutputWritten)
        guard let identity = journal.fileIdentity else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
        let evidence = StateSupportBundleCreatedEvidence(
            operationID: operationID,
            bundleID: journal.bundleID,
            previewSHA256: journal.previewSHA256,
            outputPathSHA256: journal.outputPathSHA256,
            outputSHA256: identity.sha256,
            outputBytes: identity.bytes,
            encrypted: journal.encrypted,
            recipientReferenceSHA256: journal.recipientReferenceSHA256,
            createdAt: timestamp()
        )
        try appendCreatedIfNeeded(evidence)
        try removeJournal()
        return evidence
    }

    public func abandonPreparedCreationIfNoEffect(operationID: String) throws {
        let journal = try matchingJournal(operationID, action: .create, phase: .creationPrepared)
        guard !StateMaintenanceFileSupport.exists(journal.outputPath) else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
        try appendFailureIfNeeded(journal: journal, reasonCode: "HW-SUPPORT-NO-EFFECT")
        try removeJournal()
    }

    public func beginDeletion(
        outputPath: String,
        expectedSHA256: String,
        identity: HostwrightSupportBundleFileIdentity
    ) throws -> (operationID: String, bundleID: String) {
        guard !StateMaintenanceFileSupport.exists(journalPath) else {
            throw HostwrightSupportBundleError.recoveryRequired
        }
        guard identity.sha256 == expectedSHA256,
              let receipt = try retainedCreationReceipt(
                outputPathSHA256: pathSHA256(outputPath),
                outputSHA256: expectedSHA256
              ),
              !(try deletionExists(bundleID: receipt.bundleID, outputSHA256: expectedSHA256)) else {
            throw HostwrightSupportBundleError.receiptUnavailable
        }
        let operationID = UUID().uuidString.lowercased()
        let journal = StateSupportBundleJournal(
            operationID: operationID,
            action: .delete,
            phase: .deletionPrepared,
            bundleID: receipt.bundleID,
            previewSHA256: receipt.previewSHA256,
            outputPath: outputPath,
            outputPathSHA256: pathSHA256(outputPath),
            encrypted: receipt.encrypted,
            recipientReferenceSHA256: receipt.recipientReferenceSHA256,
            fileIdentity: identity,
            preparedAt: timestamp(),
            updatedAt: timestamp()
        )
        try validate(journal)
        try SecureStatePathManager().writePrivateJSON(journal, to: journalPath)
        return (operationID, receipt.bundleID)
    }

    public func recordDeletedFile(operationID: String) throws {
        let journal = try matchingJournal(operationID, action: .delete, phase: .deletionPrepared)
        let updated = journal.replacing(phase: .deletionOutputRemoved, fileIdentity: journal.fileIdentity, updatedAt: timestamp())
        try validate(updated)
        try SecureStatePathManager().replacePrivateJSON(updated, at: journalPath)
    }

    public func completeDeletion(operationID: String) throws -> StateSupportBundleDeletedEvidence {
        let journal = try matchingJournal(operationID, action: .delete, phase: .deletionOutputRemoved)
        guard let identity = journal.fileIdentity else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
        let evidence = StateSupportBundleDeletedEvidence(
            operationID: operationID,
            bundleID: journal.bundleID,
            outputPathSHA256: journal.outputPathSHA256,
            outputSHA256: identity.sha256,
            deletedAt: timestamp()
        )
        try appendDeletedIfNeeded(evidence)
        try removeJournal()
        return evidence
    }

    public func abandonPreparedDeletionIfUnchanged(
        operationID: String,
        observedIdentity: HostwrightSupportBundleFileIdentity
    ) throws {
        let journal = try matchingJournal(operationID, action: .delete, phase: .deletionPrepared)
        guard journal.fileIdentity == observedIdentity else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
        try appendFailureIfNeeded(journal: journal, reasonCode: "HW-SUPPORT-NO-EFFECT")
        try removeJournal()
    }

    public func recover(
        inspect: (String) throws -> HostwrightSupportBundleFileIdentity?,
        delete: (String, HostwrightSupportBundleFileIdentity) throws -> Void
    ) throws -> StateSupportBundleRecoveryResult {
        guard StateMaintenanceFileSupport.exists(journalPath) else {
            return StateSupportBundleRecoveryResult(action: "no-action", bundleID: nil, safeHold: false)
        }
        let journal = try readJournal()
        let observed = try inspect(journal.outputPath)
        switch journal.phase {
        case .creationPrepared:
            guard observed == nil else {
                return StateSupportBundleRecoveryResult(action: "safe-hold", bundleID: journal.bundleID, safeHold: true)
            }
            try appendFailureIfNeeded(journal: journal, reasonCode: "HW-SUPPORT-NO-EFFECT")
            try removeJournal()
            return StateSupportBundleRecoveryResult(action: "compensated-create", bundleID: journal.bundleID, safeHold: false)
        case .creationOutputWritten:
            guard let expected = journal.fileIdentity else {
                throw HostwrightSupportBundleError.recoverySafeHold
            }
            guard let observed else {
                try appendFailureIfNeeded(journal: journal, reasonCode: "HW-SUPPORT-OUTPUT-MISSING")
                try removeJournal()
                return StateSupportBundleRecoveryResult(action: "compensated-create", bundleID: journal.bundleID, safeHold: false)
            }
            guard observed == expected else {
                return StateSupportBundleRecoveryResult(action: "safe-hold", bundleID: journal.bundleID, safeHold: true)
            }
            _ = try completeCreation(operationID: journal.operationID)
            return StateSupportBundleRecoveryResult(action: "finalized-create", bundleID: journal.bundleID, safeHold: false)
        case .deletionPrepared:
            guard let expected = journal.fileIdentity else {
                throw HostwrightSupportBundleError.recoverySafeHold
            }
            if let observed {
                guard observed == expected else {
                    return StateSupportBundleRecoveryResult(action: "safe-hold", bundleID: journal.bundleID, safeHold: true)
                }
                try delete(journal.outputPath, expected)
            }
            try recordDeletedFile(operationID: journal.operationID)
            _ = try completeDeletion(operationID: journal.operationID)
            return StateSupportBundleRecoveryResult(action: "finalized-delete", bundleID: journal.bundleID, safeHold: false)
        case .deletionOutputRemoved:
            guard observed == nil else {
                return StateSupportBundleRecoveryResult(action: "safe-hold", bundleID: journal.bundleID, safeHold: true)
            }
            _ = try completeDeletion(operationID: journal.operationID)
            return StateSupportBundleRecoveryResult(action: "finalized-delete", bundleID: journal.bundleID, safeHold: false)
        }
    }

    private func appendCreatedIfNeeded(_ evidence: StateSupportBundleCreatedEvidence) throws {
        try appendIfNeeded(
            type: HostwrightSupportBundleContract.createdEventType,
            operationID: evidence.operationID,
            message: "Support bundle creation committed.",
            payload: evidence
        )
    }

    private func appendDeletedIfNeeded(_ evidence: StateSupportBundleDeletedEvidence) throws {
        try appendIfNeeded(
            type: HostwrightSupportBundleContract.deletedEventType,
            operationID: evidence.operationID,
            message: "Exact support bundle deletion committed.",
            payload: evidence
        )
    }

    private func appendFailureIfNeeded(journal: StateSupportBundleJournal, reasonCode: String) throws {
        try appendIfNeeded(
            type: HostwrightSupportBundleContract.failedEventType,
            operationID: journal.operationID,
            message: "Support bundle operation ended without an acknowledged external effect.",
            payload: StateSupportBundleFailedEvidence(
                operationID: journal.operationID,
                bundleID: journal.bundleID,
                outputPathSHA256: journal.outputPathSHA256,
                reasonCode: reasonCode,
                failedAt: timestamp()
            )
        )
    }

    private func appendIfNeeded<T: Encodable>(
        type: String,
        operationID: String,
        message: String,
        payload: T
    ) throws {
        if try eventExists(type: type, operationID: operationID) { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        guard data.count <= 4 * 1_024, let payloadJSON = String(data: data, encoding: .utf8) else {
            throw HostwrightSupportBundleError.invalidContract
        }
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: timestamp(),
                severity: type == HostwrightSupportBundleContract.failedEventType ? .warning : .info,
                type: type,
                source: HostwrightSupportBundleContract.source,
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: message,
                payloadJSONRedacted: payloadJSON
            )
        ])
    }

    private func eventExists(type: String, operationID: String) throws -> Bool {
        try store.events.contains(
            type: type,
            source: HostwrightSupportBundleContract.source,
            payloadContains: "\"operationID\":\"\(operationID)\""
        )
    }

    private func retainedCreationReceipt(
        outputPathSHA256: String,
        outputSHA256: String
    ) throws -> StateSupportBundleCreatedEvidence? {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT payload_json_redacted FROM event_ledger
                WHERE type = ? AND source = ?
                  AND instr(payload_json_redacted, ?) > 0
                  AND instr(payload_json_redacted, ?) > 0
                ORDER BY timestamp DESC, rowid DESC
                LIMIT 4
                """,
                bindings: [
                    .text(HostwrightSupportBundleContract.createdEventType),
                    .text(HostwrightSupportBundleContract.source),
                    .text(outputPathSHA256),
                    .text(outputSHA256)
                ]
            )
            let decoder = JSONDecoder()
            for row in rows {
                guard let payload = row.first ?? nil,
                      let data = payload.data(using: .utf8),
                      let receipt = try? decoder.decode(StateSupportBundleCreatedEvidence.self, from: data),
                      receipt.outputPathSHA256 == outputPathSHA256,
                      receipt.outputSHA256 == outputSHA256 else { continue }
                return receipt
            }
            return nil
        }
    }

    private func deletionExists(bundleID: String, outputSHA256: String) throws -> Bool {
        try store.withValidatedConnection(readOnly: true) { connection in
            let rows = try connection.query(
                """
                SELECT 1 FROM event_ledger
                WHERE type = ? AND source = ?
                  AND instr(payload_json_redacted, ?) > 0
                  AND instr(payload_json_redacted, ?) > 0
                LIMIT 1
                """,
                bindings: [
                    .text(HostwrightSupportBundleContract.deletedEventType),
                    .text(HostwrightSupportBundleContract.source),
                    .text(bundleID),
                    .text(outputSHA256)
                ]
            )
            return !rows.isEmpty
        }
    }

    private func matchingJournal(
        _ operationID: String,
        action: StateSupportBundleAction,
        phase: StateSupportBundlePhase
    ) throws -> StateSupportBundleJournal {
        let journal = try readJournal()
        guard journal.operationID == operationID,
              journal.action == action,
              journal.phase == phase else {
            throw HostwrightSupportBundleError.recoveryRequired
        }
        return journal
    }

    private func readJournal() throws -> StateSupportBundleJournal {
        let data = try SecureStatePathManager().readPrivateFile(journalPath, maximumBytes: 64 * 1_024)
        let journal = try JSONDecoder().decode(StateSupportBundleJournal.self, from: data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(journal) + Data("\n".utf8) == data else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
        try validate(journal)
        return journal
    }

    private func validate(_ journal: StateSupportBundleJournal) throws {
        let identityValid = journal.fileIdentity.map {
            HostwrightSupportBundleContract.isValidSHA256($0.sha256) &&
                $0.bytes <= UInt64(HostwrightSupportBundleContract.maximumEncryptedBytes)
        } ?? true
        guard journal.schemaVersion == 1,
              UUID(uuidString: journal.operationID)?.uuidString.lowercased() == journal.operationID,
              journal.bundleID.range(of: "^support-[a-f0-9]{32}$", options: .regularExpression) != nil,
              HostwrightSupportBundleContract.isValidSHA256(journal.previewSHA256),
              HostwrightSupportBundleContract.isValidSHA256(journal.outputPathSHA256),
              isNormalizedAbsolutePath(journal.outputPath),
              pathSHA256(journal.outputPath) == journal.outputPathSHA256,
              journal.recipientReferenceSHA256.map(HostwrightSupportBundleContract.isValidSHA256) ?? true,
              identityValid,
              (journal.phase == .creationPrepared ? journal.fileIdentity == nil : true),
              (journal.phase == .creationOutputWritten || journal.action == .delete ? journal.fileIdentity != nil : true) else {
            throw HostwrightSupportBundleError.recoverySafeHold
        }
    }

    private func removeJournal() throws {
        try StateMaintenanceFileSupport.unlinkSensitiveFile(journalPath)
    }

    private func pathSHA256(_ path: String) -> String {
        StateMaintenanceFileSupport.token(["hostwright-support-path-v1", path])
    }

    private func isNormalizedAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return !components.isEmpty &&
            components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
            "/" + components.joined(separator: "/") == path
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: date())
    }
}

public struct StateSupportBundleCreatedEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationID: String
    public let bundleID: String
    public let previewSHA256: String
    public let outputPathSHA256: String
    public let outputSHA256: String
    public let outputBytes: UInt64
    public let encrypted: Bool
    public let recipientReferenceSHA256: String?
    public let createdAt: String

    public init(
        operationID: String,
        bundleID: String,
        previewSHA256: String,
        outputPathSHA256: String,
        outputSHA256: String,
        outputBytes: UInt64,
        encrypted: Bool,
        recipientReferenceSHA256: String?,
        createdAt: String
    ) {
        self.schemaVersion = 1
        self.operationID = operationID
        self.bundleID = bundleID
        self.previewSHA256 = previewSHA256
        self.outputPathSHA256 = outputPathSHA256
        self.outputSHA256 = outputSHA256
        self.outputBytes = outputBytes
        self.encrypted = encrypted
        self.recipientReferenceSHA256 = recipientReferenceSHA256
        self.createdAt = createdAt
    }
}

public struct StateSupportBundleDeletedEvidence: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let operationID: String
    public let bundleID: String
    public let outputPathSHA256: String
    public let outputSHA256: String
    public let deletedAt: String

    public init(
        operationID: String,
        bundleID: String,
        outputPathSHA256: String,
        outputSHA256: String,
        deletedAt: String
    ) {
        self.schemaVersion = 1
        self.operationID = operationID
        self.bundleID = bundleID
        self.outputPathSHA256 = outputPathSHA256
        self.outputSHA256 = outputSHA256
        self.deletedAt = deletedAt
    }
}

private struct StateSupportBundleFailedEvidence: Codable {
    let schemaVersion: Int
    let operationID: String
    let bundleID: String
    let outputPathSHA256: String
    let reasonCode: String
    let failedAt: String

    init(
        operationID: String,
        bundleID: String,
        outputPathSHA256: String,
        reasonCode: String,
        failedAt: String
    ) {
        self.schemaVersion = 1
        self.operationID = operationID
        self.bundleID = bundleID
        self.outputPathSHA256 = outputPathSHA256
        self.reasonCode = reasonCode
        self.failedAt = failedAt
    }
}

private enum StateSupportBundleAction: String, Codable {
    case create
    case delete
}

private enum StateSupportBundlePhase: String, Codable {
    case creationPrepared = "creation-prepared"
    case creationOutputWritten = "creation-output-written"
    case deletionPrepared = "deletion-prepared"
    case deletionOutputRemoved = "deletion-output-removed"
}

private struct StateSupportBundleJournal: Codable {
    let schemaVersion: Int
    let operationID: String
    let action: StateSupportBundleAction
    let phase: StateSupportBundlePhase
    let bundleID: String
    let previewSHA256: String
    let outputPath: String
    let outputPathSHA256: String
    let encrypted: Bool
    let recipientReferenceSHA256: String?
    let fileIdentity: HostwrightSupportBundleFileIdentity?
    let preparedAt: String
    let updatedAt: String

    init(
        operationID: String,
        action: StateSupportBundleAction,
        phase: StateSupportBundlePhase,
        bundleID: String,
        previewSHA256: String,
        outputPath: String,
        outputPathSHA256: String,
        encrypted: Bool,
        recipientReferenceSHA256: String?,
        fileIdentity: HostwrightSupportBundleFileIdentity?,
        preparedAt: String,
        updatedAt: String
    ) {
        self.schemaVersion = 1
        self.operationID = operationID
        self.action = action
        self.phase = phase
        self.bundleID = bundleID
        self.previewSHA256 = previewSHA256
        self.outputPath = outputPath
        self.outputPathSHA256 = outputPathSHA256
        self.encrypted = encrypted
        self.recipientReferenceSHA256 = recipientReferenceSHA256
        self.fileIdentity = fileIdentity
        self.preparedAt = preparedAt
        self.updatedAt = updatedAt
    }

    func replacing(
        phase: StateSupportBundlePhase,
        fileIdentity: HostwrightSupportBundleFileIdentity?,
        updatedAt: String
    ) -> StateSupportBundleJournal {
        StateSupportBundleJournal(
            operationID: operationID,
            action: action,
            phase: phase,
            bundleID: bundleID,
            previewSHA256: previewSHA256,
            outputPath: outputPath,
            outputPathSHA256: outputPathSHA256,
            encrypted: encrypted,
            recipientReferenceSHA256: recipientReferenceSHA256,
            fileIdentity: fileIdentity,
            preparedAt: preparedAt,
            updatedAt: updatedAt
        )
    }
}
