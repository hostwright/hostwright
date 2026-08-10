import CryptoKit
import Foundation
import HostwrightState
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightSecrets

final class SecretRecoveryCommandTests: XCTestCase {
    func testResumeConflictUsesSecretConflictDiagnostic() throws {
        try withFixture { fixture in
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: UUID(),
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )
            try fixture.persistActiveConflict()

            let result = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertTrue(result.standardError.contains("HW-SECRET-004"))
            XCTAssertFalse(result.standardError.contains("HW-STATE-001"))
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.store.operationGroups.load(id: journal.id)?.status,
                .interrupted
            )
        }
    }

    func testResumeFinalizesAnAlreadyAppliedCreateByExactMetadataObservation() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: itemID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )

            let result = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains(#""status":"already-succeeded""#))
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            let group = try XCTUnwrap(
                try fixture.store.operationGroups.load(id: journal.id)
            )
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(group.checkpoint, "keychain-effect-verified")
            XCTAssertEqual(
                try fixture.store.operationGroupSteps.load(groupID: journal.id)
                    .map(\.stepKey),
                ["keychain-effect-reobserved"]
            )
        }
    }

    func testResumeCompletesPendingDeleteAndVerifiesExactAbsence() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 3
            )
            let journal = try fixture.persistInterrupted(
                operation: "delete",
                expectedItemID: itemID,
                targetItemID: nil,
                expectedVersion: 2,
                targetVersion: nil,
                rollbackAvailable: false
            )

            let result = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains(#""status":"succeeded""#))
            XCTAssertEqual(fixture.manager.mutationCount, 1)
            XCTAssertTrue(fixture.manager.isEmpty)
            let group = try XCTUnwrap(
                try fixture.store.operationGroups.load(id: journal.id)
            )
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(group.checkpoint, "keychain-effect-verified")
        }
    }

    func testRollbackCompensatesOnlyTheVerifiedCreateAndIsIdempotent() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: itemID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )

            let first = fixture.recover(
                action: "rollback",
                journal: journal
            )
            let second = fixture.recover(
                action: "rollback",
                journal: journal
            )

            XCTAssertEqual(first.exitCode, 0, first.standardError)
            XCTAssertTrue(first.standardOutput.contains(#""status":"compensated""#))
            XCTAssertEqual(second.exitCode, 0, second.standardError)
            XCTAssertTrue(second.standardOutput.contains(#""status":"already-succeeded""#))
            XCTAssertEqual(fixture.manager.mutationCount, 1)
            XCTAssertTrue(fixture.manager.isEmpty)
            let group = try XCTUnwrap(
                try fixture.store.operationGroups.load(id: journal.id)
            )
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(group.checkpoint, "keychain-recovery-compensated")
        }
    }

    func testValueUnsafeUpdateRemainsInSafeHoldUntilTargetIsObserved() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 3
            )
            let journal = try fixture.persistInterrupted(
                operation: "update",
                expectedItemID: itemID,
                targetItemID: itemID,
                expectedVersion: 2,
                targetVersion: 3,
                rollbackAvailable: false
            )

            let held = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(
                held.exitCode,
                CLIExitCode.partialFailure.rawValue
            )
            XCTAssertTrue(held.standardError.contains("safe hold"))
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            var group = try XCTUnwrap(
                try fixture.store.operationGroups.load(id: journal.id)
            )
            XCTAssertEqual(group.status, .interrupted)
            XCTAssertEqual(group.checkpoint, "keychain-recovery-safe-hold")

            _ = fixture.manager.seed(
                reference: fixture.reference,
                version: 3,
                itemID: itemID
            )
            let resumed = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(resumed.exitCode, 0, resumed.standardError)
            XCTAssertTrue(resumed.standardOutput.contains(#""status":"already-succeeded""#))
            group = try XCTUnwrap(
                try fixture.store.operationGroups.load(id: journal.id)
            )
            XCTAssertEqual(group.status, .succeeded)
            XCTAssertEqual(fixture.manager.mutationCount, 0)
        }
    }

    func testConfirmationMismatchFailsBeforeKeychainObservation() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: itemID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )

            let result = HostwrightCLI.run(
                arguments: [
                    "recovery", "resume",
                    "--group", journal.id,
                    "--confirm-plan", String(repeating: "f", count: 64),
                    "--state-db", fixture.statePath,
                    "--output", "json"
                ],
                environment: fixture.environment
            )

            XCTAssertEqual(
                result.exitCode,
                CLIExitCode.confirmationMismatch.rawValue
            )
            XCTAssertEqual(fixture.manager.observationCount, 0)
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.store.operationGroups.load(id: journal.id)?.status,
                .interrupted
            )
        }
    }

    func testResumeReclaimsAnExpiredActiveSecretMutationAfterProcessLoss() throws {
        try withFixture { fixture in
            let itemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: itemID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true,
                leaveActiveWithExpiry: "2000-01-01T00:00:00Z"
            )

            let result = fixture.recover(
                action: "resume",
                journal: journal
            )

            XCTAssertEqual(result.exitCode, 0, result.standardError)
            XCTAssertTrue(result.standardOutput.contains(#""status":"already-succeeded""#))
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.store.operationGroups.load(id: journal.id)?.status,
                .succeeded
            )
        }
    }

    func testResumeDoesNotFinalizeSameVersionReplacement() throws {
        try withFixture { fixture in
            let intendedItemID = UUID()
            let replacementItemID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            XCTAssertNotEqual(replacementItemID, intendedItemID)
            let journal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: intendedItemID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )

            let result = fixture.recover(action: "resume", journal: journal)

            XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertTrue(result.standardError.contains("safe hold"))
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.manager.check(reference: fixture.reference).itemID,
                replacementItemID
            )
            XCTAssertEqual(
                try fixture.store.operationGroups.load(id: journal.id)?.status,
                .interrupted
            )
        }
    }

    func testRollbackAndDeleteRecoveryNeverDeleteReplacementItem() throws {
        try withFixture { fixture in
            let intendedCreateID = UUID()
            let replacementCreateID = fixture.manager.seed(
                reference: fixture.reference,
                version: 1
            )
            let createJournal = try fixture.persistInterrupted(
                operation: "create",
                expectedItemID: nil,
                targetItemID: intendedCreateID,
                expectedVersion: nil,
                targetVersion: 1,
                rollbackAvailable: true
            )

            let rollback = fixture.recover(
                action: "rollback",
                journal: createJournal
            )

            XCTAssertEqual(
                rollback.exitCode,
                CLIExitCode.partialFailure.rawValue
            )
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.manager.check(reference: fixture.reference).itemID,
                replacementCreateID
            )
        }

        try withFixture { fixture in
            let intendedDeleteID = UUID()
            let replacementDeleteID = fixture.manager.seed(
                reference: fixture.reference,
                version: 3
            )
            let deleteJournal = try fixture.persistInterrupted(
                operation: "delete",
                expectedItemID: intendedDeleteID,
                targetItemID: nil,
                expectedVersion: 2,
                targetVersion: nil,
                rollbackAvailable: false
            )

            let resumed = fixture.recover(
                action: "resume",
                journal: deleteJournal
            )

            XCTAssertEqual(
                resumed.exitCode,
                CLIExitCode.partialFailure.rawValue
            )
            XCTAssertEqual(fixture.manager.mutationCount, 0)
            XCTAssertEqual(
                try fixture.manager.check(reference: fixture.reference).itemID,
                replacementDeleteID
            )
        }
    }

    private func withFixture(
        _ body: (SecretRecoveryFixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-secret-recovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try SecretRecoveryFixture(directory: directory)
        try body(fixture)
    }
}

private struct SecretRecoveryJournal {
    let id: String
    let planHash: String
}

private final class SecretRecoveryFixture {
    let statePath: String
    let store: SQLiteStateStore
    let manager = RecoverySecretManager()
    let reference: HostwrightSecretReference
    let environment: CLIEnvironment

    init(directory: URL) throws {
        statePath = directory.appendingPathComponent("state.sqlite").path
        store = SQLiteStateStore(path: statePath)
        try store.migrate()
        reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.recovery/token"
        )
        let manager = self.manager
        environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in throw CocoaError(.fileReadNoSuchFile) },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            secretManager: { manager },
            swiftVersion: { "Swift 6.3.3" },
            platformSnapshot: {
                PlatformSnapshot(
                    macOSMajorVersion: 26,
                    architecture: "arm64"
                )
            },
            operatingSystemDescription: { "macOS 26" }
        )
    }

    func persistInterrupted(
        operation: String,
        expectedItemID: UUID?,
        targetItemID: UUID?,
        expectedVersion: Int?,
        targetVersion: Int?,
        rollbackAvailable: Bool,
        leaveActiveWithExpiry: String? = nil
    ) throws -> SecretRecoveryJournal {
        let referenceSHA256 = recoveryTestSHA256(reference.rawValue)
        let planHash = recoveryTestSHA256([
            operation,
            referenceSHA256,
            expectedItemID.map { $0.uuidString.lowercased() } ?? "none",
            targetItemID.map { $0.uuidString.lowercased() } ?? "none",
            expectedVersion.map(String.init) ?? "none",
            targetVersion.map(String.init) ?? "none"
        ].joined(separator: "\n"))
        let operationID = HostwrightResourceUUID.generate()
        let timestamp = "2026-07-24T00:00:00Z"
        let intent = try recoveryTestJSON([
            "expectedItemID":
                expectedItemID?.uuidString.lowercased() as Any? ?? NSNull(),
            "expectedVersion": expectedVersion as Any? ?? NSNull(),
            "secretReferenceSHA256": referenceSHA256,
            "targetItemID":
                targetItemID?.uuidString.lowercased() as Any? ?? NSNull(),
            "targetVersion": targetVersion as Any? ?? NSNull()
        ])
        let group = OperationGroupRecord(
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
            lockExpiresAt:
                leaveActiveWithExpiry ?? "9999-01-01T00:00:00Z",
            rollbackAvailable: rollbackAvailable,
            manualRecoveryHintRedacted: "Inspect managed Keychain metadata.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: intent,
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: intent,
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: #"{"status":"pending"}"#
        )
        XCTAssertNotNil(try store.operationGroups.acquire(group).acquired)
        if leaveActiveWithExpiry != nil {
            return SecretRecoveryJournal(id: operationID, planHash: planHash)
        }
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "keychain-effect-ambiguous",
            manualRecoveryHintRedacted: "Inspect managed Keychain metadata.",
            updatedAt: "2026-07-24T00:00:01Z",
            metadataJSONRedacted: #"{"status":"interrupted"}"#
        )
        return SecretRecoveryJournal(id: operationID, planHash: planHash)
    }

    func recover(
        action: String,
        journal: SecretRecoveryJournal
    ) -> CLIRunResult {
        HostwrightCLI.run(
            arguments: [
                "recovery", action,
                "--group", journal.id,
                "--confirm-plan", journal.planHash,
                "--state-db", statePath,
                "--output", "json"
            ],
            environment: environment
        )
    }

    func persistActiveConflict() throws {
        let referenceSHA256 = recoveryTestSHA256(reference.rawValue)
        let operationID = HostwrightResourceUUID.generate()
        let group = OperationGroupRecord(
            id: operationID,
            operationID: operationID,
            groupKind: "secret-mutation",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "update",
            status: .active,
            groupIdempotencyKey: "secret:\(referenceSHA256)",
            planHash: String(repeating: "b", count: 64),
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-cli:\(operationID)",
            lockExpiresAt: "9999-01-01T00:00:00Z",
            rollbackAvailable: false,
            manualRecoveryHintRedacted: "Inspect managed Keychain metadata.",
            createdAt: "2026-07-24T00:00:02Z",
            updatedAt: "2026-07-24T00:00:02Z",
            metadataJSONRedacted: "{}",
            fencingToken: HostwrightResourceUUID.generate(),
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: #"{"status":"pending"}"#
        )
        XCTAssertNotNil(try store.operationGroups.acquire(group).acquired)
    }
}

private final class RecoverySecretManager: SecretManager, @unchecked Sendable {
    private let lock = NSLock()
    private var metadataByReference: [
        HostwrightSecretReference: SecretMetadata
    ] = [:]
    private(set) var mutationCount = 0
    private(set) var observationCount = 0

    var isEmpty: Bool {
        lock.withLock { metadataByReference.isEmpty }
    }

    func seed(
        reference: HostwrightSecretReference,
        version: Int,
        itemID: UUID = UUID()
    ) -> UUID {
        lock.withLock {
            metadataByReference[reference] = SecretMetadata(
                reference: reference,
                itemID: itemID,
                version: version,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(version)),
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            )
        }
        return itemID
    }

    func readString(
        reference: HostwrightSecretReference
    ) throws -> String {
        throw SecretStoreError.backendUnavailable(
            "Recovery tests do not read secret values."
        )
    }

    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        throw SecretStoreError.backendUnavailable(
            "Recovery never recreates secret bytes."
        )
    }

    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        throw SecretStoreError.backendUnavailable(
            "Recovery never replays secret bytes."
        )
    }

    func listMetadata() throws -> [SecretMetadata] {
        lock.withLock {
            observationCount += 1
            return metadataByReference.values.sorted {
                $0.reference.rawValue < $1.reference.rawValue
            }
        }
    }

    func check(
        reference: HostwrightSecretReference
    ) throws -> SecretMetadata {
        try lock.withLock {
            guard let metadata = metadataByReference[reference] else {
                throw SecretStoreError.notFound("Secret was not found.")
            }
            return metadata
        }
    }

    func delete(
        reference: HostwrightSecretReference,
        expectedItemID: UUID
    ) throws {
        try lock.withLock {
            guard let existing = metadataByReference[reference] else {
                throw SecretStoreError.notFound("Secret was not found.")
            }
            guard existing.itemID == expectedItemID else {
                throw SecretStoreError.concurrentMutation(
                    "Secret changed concurrently."
                )
            }
            metadataByReference.removeValue(forKey: reference)
            mutationCount += 1
        }
    }
}

private func recoveryTestSHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private func recoveryTestJSON(
    _ object: [String: Any]
) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return try XCTUnwrap(String(data: data, encoding: .utf8))
}
