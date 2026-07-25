import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

struct SecretCommandRunner {
    let options: SecretCLIOptions
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        let manager = environment.secretManager()
        switch options.action {
        case .list:
            return renderList(try mapped(manager.listMetadata))
        case .check(let reference):
            return renderMetadata(
                operation: "check",
                metadata: try mapped {
                    try manager.check(reference: reference)
                }
            )
        case .create(let reference):
            let value = try secretValue()
            let targetItemID = UUID()
            return try mutate(
                operation: "create",
                reference: reference,
                expectedItemID: nil,
                targetItemID: targetItemID,
                expectedVersion: nil,
                targetVersion: 1
            ) {
                try manager.create(
                    reference: reference,
                    value: value,
                    itemID: targetItemID
                )
            }
        case .update(let reference):
            let existing = try mapped {
                try manager.check(reference: reference)
            }
            guard existing.version < Int.max else {
                throw diagnostic(
                    for: .corruptedMetadata(
                        "Keychain item version is invalid for \(reference.redactedDescription)."
                    )
                )
            }
            let value = try secretValue()
            return try mutate(
                operation: "update",
                reference: reference,
                expectedItemID: existing.itemID,
                targetItemID: existing.itemID,
                expectedVersion: existing.version,
                targetVersion: existing.version + 1
            ) {
                try manager.update(
                    reference: reference,
                    value: value,
                    expectedItemID: existing.itemID
                )
            }
        case .delete(let reference):
            let existing = try mapped {
                try manager.check(reference: reference)
            }
            return try mutate(
                operation: "delete",
                reference: reference,
                expectedItemID: existing.itemID,
                targetItemID: nil,
                expectedVersion: existing.version,
                targetVersion: nil
            ) {
                try manager.delete(
                    reference: reference,
                    expectedItemID: existing.itemID
                )
                return nil
            }
        }
    }

    private func secretValue() throws -> HostwrightSecretValue {
        do {
            return try HostwrightSecretValue(
                utf8Data: environment.readSecretInput()
            )
        } catch let error as SecretStoreError {
            throw diagnostic(for: error)
        }
    }

    private func mutate(
        operation: String,
        reference: HostwrightSecretReference,
        expectedItemID: UUID?,
        targetItemID: UUID?,
        expectedVersion: Int?,
        targetVersion: Int?,
        effect: () throws -> SecretMetadata?
    ) throws -> CLIRunResult {
        let configuration: StateStoreConfiguration
        do {
            configuration = try hostwrightStateStoreConfiguration(
                explicitPath: options.stateDatabasePath,
                environment: environment
            )
        } catch {
            throw stateDiagnostic()
        }

        let store = SQLiteStateStore(configuration: configuration)
        do {
            try store.migrate()
        } catch {
            throw stateDiagnostic()
        }

        let journal = mutationJournal(
            operation: operation,
            reference: reference,
            expectedItemID: expectedItemID,
            targetItemID: targetItemID,
            expectedVersion: expectedVersion,
            targetVersion: targetVersion
        )
        do {
            let acquired = try store.operationGroups.acquire(journal.record)
            guard acquired.acquired?.id == journal.record.id else {
                throw HostwrightDiagnostic(
                    code: .secretConflict,
                    message: "Another secret mutation with the same durable identity is active."
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch {
            throw stateDiagnostic()
        }

        do {
            let metadata = try mapped(effect)
            try validateEffect(journal: journal, metadata: metadata)
            do {
                try recordSuccess(
                    store: store,
                    journal: journal,
                    metadata: metadata
                )
            } catch {
                throw HostwrightDiagnostic(
                    code: .secretPartialEffect,
                    message: "The Keychain mutation completed, but its durable audit checkpoint could not be finalized. Inspect the active secret-mutation recovery record before retrying."
                )
            }
            if let metadata {
                return renderMetadata(operation: operation, metadata: metadata)
            }
            return renderDeletion(
                reference: reference,
                groupID: journal.record.id
            )
        } catch let diagnostic as HostwrightDiagnostic {
            try finishFailure(
                store: store,
                journal: journal,
                diagnostic: diagnostic
            )
            throw diagnostic
        } catch {
            let diagnostic = stateDiagnostic()
            try finishFailure(
                store: store,
                journal: journal,
                diagnostic: diagnostic
            )
            throw diagnostic
        }
    }

    private func recordSuccess(
        store: SQLiteStateStore,
        journal: MutationJournal,
        metadata: SecretMetadata?
    ) throws {
        let timestamp = hostwrightTimestamp()
        try store.operationGroupSteps.append(
            OperationGroupStepRecord(
                id: "secret-step-\(UUID().uuidString.lowercased())",
                groupID: journal.record.id,
                stepKey: "keychain-effect-verified",
                direction: .forward,
                plannedActionType: journal.operation,
                serviceName: nil,
                resourceIdentifier: nil,
                stepIdempotencyKey: "\(journal.record.planHash):effect",
                status: .succeeded,
                startedAt: journal.record.createdAt,
                updatedAt: timestamp,
                finishedAt: timestamp,
                lastErrorRedacted: nil,
                manualRecoveryHintRedacted: "No recovery is required.",
                metadataJSONRedacted: jsonPayload([
                    "itemID": jsonValue(metadata?.itemID),
                    "secretReferenceSHA256": journal.referenceSHA256,
                    "version": jsonValue(metadata?.version)
                ])
            ),
            expectedFencingToken: journal.record.fencingToken
        )
        try store.events.append([
            EventRecord(
                id: "secret-event-\(UUID().uuidString.lowercased())",
                timestamp: timestamp,
                severity: .info,
                type: "secret.\(journal.operation).succeeded",
                source: "hostwright-cli",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: nil,
                message: "Hostwright completed a managed Keychain metadata mutation.",
                payloadJSONRedacted: jsonPayload([
                    "itemID": jsonValue(metadata?.itemID),
                    "secretReferenceSHA256": journal.referenceSHA256,
                    "version": jsonValue(metadata?.version)
                ])
            )
        ])
        let verification = jsonPayload([
            "itemID": jsonValue(metadata?.itemID),
            "secretReferenceSHA256": journal.referenceSHA256,
            "status": "succeeded",
            "version": jsonValue(metadata?.version)
        ])
        try store.operationGroups.recordCheckpoint(
            groupID: journal.record.id,
            expectedFencingToken: journal.record.fencingToken,
            checkpoint: "keychain-effect-verified",
            verificationJSONRedacted: verification,
            updatedAt: timestamp
        )
        try store.operationGroups.finish(
            groupID: journal.record.id,
            status: .succeeded,
            checkpoint: "keychain-effect-verified",
            manualRecoveryHintRedacted: "No recovery is required.",
            updatedAt: timestamp,
            metadataJSONRedacted: verification
        )
    }

    private func finishFailure(
        store: SQLiteStateStore,
        journal: MutationJournal,
        diagnostic: HostwrightDiagnostic
    ) throws {
        let partial = diagnostic.code == .secretPartialEffect
        let status = partial ? "interrupted" : "failed"
        let checkpoint = partial
            ? "keychain-effect-ambiguous"
            : "keychain-effect-rejected"
        let timestamp = hostwrightTimestamp()
        let verification = jsonPayload([
            "errorCode": diagnostic.code.rawValue,
            "secretReferenceSHA256": journal.referenceSHA256,
            "status": status
        ])
        do {
            try store.operationGroups.recordCheckpoint(
                groupID: journal.record.id,
                expectedFencingToken: journal.record.fencingToken,
                checkpoint: checkpoint,
                verificationJSONRedacted: verification,
                updatedAt: timestamp
            )
            try store.operationGroups.finish(
                groupID: journal.record.id,
                status: partial ? .interrupted : .failed,
                checkpoint: checkpoint,
                manualRecoveryHintRedacted: partial
                    ? "Check the exact managed Keychain item metadata before retrying this operation."
                    : "Correct the reported failure and retry the operation.",
                updatedAt: timestamp,
                metadataJSONRedacted: verification
            )
        } catch {
            throw HostwrightDiagnostic(
                code: .secretPartialEffect,
                message: "The secret operation failed and its durable recovery checkpoint could not be finalized. Inspect the active secret-mutation record before retrying."
            )
        }
    }

    private func mutationJournal(
        operation: String,
        reference: HostwrightSecretReference,
        expectedItemID: UUID?,
        targetItemID: UUID?,
        expectedVersion: Int?,
        targetVersion: Int?
    ) -> MutationJournal {
        let operationID = UUID().uuidString.lowercased()
        let fencingToken = UUID().uuidString.lowercased()
        let referenceSHA256 = sha256(reference.rawValue)
        let planPayload = [
            operation,
            referenceSHA256,
            expectedItemID.map(canonicalItemID) ?? "none",
            targetItemID.map(canonicalItemID) ?? "none",
            expectedVersion.map(String.init) ?? "none",
            targetVersion.map(String.init) ?? "none"
        ].joined(separator: "\n")
        let planHash = sha256(planPayload)
        let timestamp = hostwrightTimestamp()
        return MutationJournal(
            operation: operation,
            referenceSHA256: referenceSHA256,
            expectedItemID: expectedItemID,
            targetItemID: targetItemID,
            targetVersion: targetVersion,
            record: OperationGroupRecord(
                id: operationID,
                operationID: operationID,
                groupKind: "secret-mutation",
                projectID: nil,
                serviceName: nil,
                plannedActionType: operation,
                status: .active,
                groupIdempotencyKey: "secret:\(referenceSHA256)",
                planHash: planHash,
                checkpoint: "intent-persisted",
                lockOwner: "hostwright-cli:\(operationID)",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 900,
                    to: timestamp
                ),
                rollbackAvailable: operation == "create",
                manualRecoveryHintRedacted: "Inspect the exact managed Keychain item metadata before resuming or compensating this mutation.",
                createdAt: timestamp,
                updatedAt: timestamp,
                metadataJSONRedacted: jsonPayload([
                    "expectedItemID": jsonValue(expectedItemID),
                    "expectedVersion": jsonValue(expectedVersion),
                    "secretReferenceSHA256": referenceSHA256,
                    "targetItemID": jsonValue(targetItemID),
                    "targetVersion": jsonValue(targetVersion)
                ]),
                fencingToken: fencingToken,
                intentJSONRedacted: jsonPayload([
                    "expectedItemID": jsonValue(expectedItemID),
                    "expectedVersion": jsonValue(expectedVersion),
                    "secretReferenceSHA256": referenceSHA256,
                    "targetItemID": jsonValue(targetItemID),
                    "targetVersion": jsonValue(targetVersion)
                ]),
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: jsonPayload([
                    "status": "pending"
                ])
            )
        )
    }

    private func renderList(_ metadata: [SecretMetadata]) -> CLIRunResult {
        if options.output == .json {
            return CLIRunResult(
                standardOutput: renderJSON([
                    "kind": "secretList",
                    "items": metadata.map(metadataObject)
                ])
            )
        }
        var lines = ["Hostwright managed Keychain secrets"]
        if metadata.isEmpty {
            lines.append("- none")
        } else {
            lines += metadata.map {
                "- \($0.reference.rawValue) (version \($0.version))"
            }
        }
        return CLIRunResult(standardOutput: lines.joined(separator: "\n") + "\n")
    }

    private func renderMetadata(
        operation: String,
        metadata: SecretMetadata
    ) -> CLIRunResult {
        if options.output == .json {
            var object = metadataObject(metadata)
            object["kind"] = "secretMutation"
            object["operation"] = operation
            return CLIRunResult(standardOutput: renderJSON(object))
        }
        return CLIRunResult(
            standardOutput: """
            Hostwright Keychain secret \(operation)
            Reference: \(metadata.reference.rawValue)
            Version: \(metadata.version)
            Accessibility: \(metadata.accessibility.rawValue)
            Synchronizable: \(metadata.synchronizable)

            """
        )
    }

    private func renderDeletion(
        reference: HostwrightSecretReference,
        groupID: String
    ) -> CLIRunResult {
        if options.output == .json {
            return CLIRunResult(
                standardOutput: renderJSON([
                    "kind": "secretMutation",
                    "operation": "delete",
                    "reference": reference.rawValue,
                    "status": "deleted",
                    "operationGroupID": groupID
                ])
            )
        }
        return CLIRunResult(
            standardOutput: """
            Hostwright Keychain secret delete
            Reference: \(reference.rawValue)
            Status: deleted

            """
        )
    }

    private func metadataObject(_ metadata: SecretMetadata) -> [String: Any] {
        [
            "reference": metadata.reference.rawValue,
            "itemID": canonicalItemID(metadata.itemID),
            "version": metadata.version,
            "createdAt": ISO8601DateFormatter().string(from: metadata.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: metadata.updatedAt),
            "accessibility": metadata.accessibility.rawValue,
            "synchronizable": metadata.synchronizable
        ]
    }

    private func mapped<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as SecretStoreError {
            throw diagnostic(for: error)
        }
    }

    private func diagnostic(for error: SecretStoreError) -> HostwrightDiagnostic {
        let code: HostwrightErrorCode
        switch error {
        case .invalidReference, .invalidValue, .corruptedMetadata:
            code = .secretInvalid
        case .backendUnavailable, .interactionNotAllowed:
            code = .secretUnavailable
        case .notFound:
            code = .secretNotFound
        case .duplicate, .unmanaged, .concurrentMutation:
            code = .secretConflict
        case .permissionDenied:
            code = .secretDenied
        case .cancelled:
            code = .secretCancelled
        case .partialEffect:
            code = .secretPartialEffect
        }
        return HostwrightDiagnostic(
            code: code,
            message: RuntimeRedactionPolicy.default.redact(error.description)
        )
    }

    private func stateDiagnostic() -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .stateStoreUnavailable,
            message: "The secure local state store is unavailable for the secret audit record."
        )
    }

    private func validateEffect(
        journal: MutationJournal,
        metadata: SecretMetadata?
    ) throws {
        switch journal.operation {
        case "create", "update":
            guard metadata?.itemID == journal.targetItemID,
                  metadata?.version == journal.targetVersion else {
                throw HostwrightDiagnostic(
                    code: .secretPartialEffect,
                    message: "The Keychain mutation returned metadata that does not match its durable item identity. Inspect the active secret-mutation recovery record before retrying."
                )
            }
        case "delete":
            guard metadata == nil else {
                throw HostwrightDiagnostic(
                    code: .secretPartialEffect,
                    message: "The Keychain delete returned unexpected metadata. Inspect the active secret-mutation recovery record before retrying."
                )
            }
        default:
            preconditionFailure("Unsupported secret mutation.")
        }
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func renderJSON(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8)! + "\n"
    }

    private func jsonValue(_ value: Int?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    private func jsonValue(_ value: UUID?) -> Any {
        value.map(canonicalItemID) ?? NSNull()
    }

    private func canonicalItemID(_ itemID: UUID) -> String {
        itemID.uuidString.lowercased()
    }
}

private struct MutationJournal {
    let operation: String
    let referenceSHA256: String
    let expectedItemID: UUID?
    let targetItemID: UUID?
    let targetVersion: Int?
    let record: OperationGroupRecord
}
