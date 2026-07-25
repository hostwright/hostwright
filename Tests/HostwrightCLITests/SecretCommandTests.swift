import Darwin
import CryptoKit
import Foundation
import HostwrightState
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightSecrets

final class SecretCommandTests: XCTestCase {
    func testSecretInputReaderUsesPipedBytesWithoutTextConversion() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { close(descriptors[0]) }
        let payload = Data("line-one\nline-two".utf8)
        let written = payload.withUnsafeBytes { bytes in
            Darwin.write(descriptors[1], bytes.baseAddress, bytes.count)
        }
        XCTAssertEqual(written, payload.count)
        XCTAssertEqual(close(descriptors[1]), 0)

        XCTAssertEqual(
            try HostwrightSecretInputReader.readBytes(
                fileDescriptor: descriptors[0],
                stopAtNewline: false
            ),
            payload
        )
    }

    func testParserAcceptsOnlyMetadataArgumentsAndNeverSecretValues() throws {
        let reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.registry/token"
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "secret", "create", reference.rawValue,
                "--state-db", "/tmp/state.sqlite",
                "--output", "json"
            ]),
            .secret(
                options: SecretCLIOptions(
                    action: .create(reference),
                    stateDatabasePath: "/tmp/state.sqlite",
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["secret", "update", reference.rawValue]),
            .secret(
                options: SecretCLIOptions(
                    action: .update(reference),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["secret", "list", "--json"]),
            .secret(
                options: SecretCLIOptions(
                    action: .list,
                    stateDatabasePath: nil,
                    output: .json
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["secret", "check", reference.rawValue]),
            .secret(
                options: SecretCLIOptions(
                    action: .check(reference),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: ["secret", "delete", reference.rawValue]),
            .secret(
                options: SecretCLIOptions(
                    action: .delete(reference),
                    stateDatabasePath: nil,
                    output: .text
                )
            )
        )

        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "secret", "create", reference.rawValue, "secret-on-argv"
            ])
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["secret", "list", reference.rawValue]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["secret", "create"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["secret", "unknown"]))
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "secret", "create", "local-file:///Users/dev/.config/api-token"
            ])
        ) { error in
            guard let usageError = error as? CLIUsageError else {
                return XCTFail("Expected CLIUsageError, got \(error).")
            }
            XCTAssertEqual(
                usageError.message,
                "secret item references must use keychain://<service>/<account>."
            )
        }
        XCTAssertThrowsError(
            try CLICommand.parse(arguments: [
                "secret", "check", reference.rawValue, "--json", "--output", "text"
            ])
        )
    }

    func testCRUDUsesInputBoundaryAndPersistsOnlyRedactedAuditMetadata() throws {
        try withSecureTemporaryDirectory { directory in
            let statePath = directory.appendingPathComponent("state.sqlite").path
            let manager = TestSecretManager()
            let input = SecretInputBox("first-value")
            let environment = secretEnvironment(manager: manager, input: input)
            let reference = "keychain://hostwright.registry/token"

            let created = HostwrightCLI.run(
                arguments: [
                    "secret", "create", reference,
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: environment
            )
            XCTAssertEqual(created.exitCode, 0, created.standardError)
            XCTAssertTrue(created.standardOutput.contains(#""operation":"create""#))
            XCTAssertTrue(created.standardOutput.contains(#""version":1"#))
            XCTAssertFalse(created.standardOutput.contains("first-value"))

            input.value = "second-value"
            let updated = HostwrightCLI.run(
                arguments: [
                    "secret", "update", reference,
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: environment
            )
            XCTAssertEqual(updated.exitCode, 0, updated.standardError)
            XCTAssertTrue(updated.standardOutput.contains(#""version":2"#))
            XCTAssertFalse(updated.standardOutput.contains("second-value"))

            let listed = HostwrightCLI.run(
                arguments: ["secret", "list", "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(listed.exitCode, 0, listed.standardError)
            let listedJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: Data(listed.standardOutput.utf8)
                ) as? [String: Any]
            )
            let listedItems = try XCTUnwrap(
                listedJSON["items"] as? [[String: Any]]
            )
            XCTAssertEqual(listedItems.first?["reference"] as? String, reference)
            XCTAssertFalse(listed.standardOutput.contains("second-value"))

            let checked = HostwrightCLI.run(
                arguments: ["secret", "check", reference, "--output", "json"],
                environment: environment
            )
            XCTAssertEqual(checked.exitCode, 0, checked.standardError)
            XCTAssertTrue(checked.standardOutput.contains(#""version":2"#))

            let deleted = HostwrightCLI.run(
                arguments: [
                    "secret", "delete", reference,
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: environment
            )
            XCTAssertEqual(deleted.exitCode, 0, deleted.standardError)
            XCTAssertTrue(deleted.standardOutput.contains(#""operation":"delete""#))
            XCTAssertFalse(deleted.standardOutput.contains("second-value"))

            let store = SQLiteStateStore(path: statePath)
            let groups = try store.operationGroups.loadAll()
                .filter { $0.groupKind == "secret-mutation" }
            XCTAssertEqual(groups.count, 3)
            XCTAssertTrue(groups.allSatisfy { $0.status == .succeeded })
            XCTAssertTrue(groups.allSatisfy { HostwrightResourceUUID.isValid($0.id) })
            XCTAssertEqual(Set(groups.map(\.groupIdempotencyKey)).count, 1)
            let intents = try Dictionary(
                uniqueKeysWithValues: groups.map {
                    ($0.plannedActionType, try jsonObject($0.intentJSONRedacted))
                }
            )
            let createdItemID = try XCTUnwrap(
                intents["create"]?["targetItemID"] as? String
            )
            XCTAssertTrue(HostwrightResourceUUID.isValid(createdItemID))
            XCTAssertTrue(intents["create"]?["expectedItemID"] is NSNull)
            XCTAssertEqual(
                intents["update"]?["expectedItemID"] as? String,
                createdItemID
            )
            XCTAssertEqual(
                intents["update"]?["targetItemID"] as? String,
                createdItemID
            )
            XCTAssertEqual(
                intents["delete"]?["expectedItemID"] as? String,
                createdItemID
            )
            XCTAssertTrue(intents["delete"]?["targetItemID"] is NSNull)
            for group in groups {
                let verification = try jsonObject(group.verificationJSONRedacted)
                XCTAssertEqual(verification["status"] as? String, "succeeded")
            }
            let persisted = try Data(contentsOf: URL(fileURLWithPath: statePath))
            XCTAssertNil(persisted.range(of: Data("first-value".utf8)))
            XCTAssertNil(persisted.range(of: Data("second-value".utf8)))
            let diagnostics = try store.diagnostics.loadExport(
                query: DiagnosticsExportQuery(
                    projectID: nil,
                    manifest: nil,
                    generatedAt: "2026-07-24T00:00:00Z"
                )
            )
            let diagnosticsJSON = try diagnostics.jsonString()
            XCTAssertFalse(diagnosticsJSON.contains("first-value"))
            XCTAssertFalse(diagnosticsJSON.contains("second-value"))
            XCTAssertFalse(diagnosticsJSON.contains(reference))
            XCTAssertFalse(
                groups.contains {
                    $0.intentJSONRedacted.contains(reference) ||
                    $0.metadataJSONRedacted.contains(reference) ||
                    $0.verificationJSONRedacted.contains(reference)
                }
            )
        }
    }

    func testMalformedInputFailsBeforeKeychainMutation() throws {
        try withSecureTemporaryDirectory { directory in
            let manager = TestSecretManager()
            let input = SecretInputBox(data: Data([0xC3, 0x28]))
            let result = HostwrightCLI.run(
                arguments: [
                    "secret", "create", "keychain://hostwright.registry/token",
                    "--state-db", directory.appendingPathComponent("state.sqlite").path,
                    "--output", "json"
                ],
                environment: secretEnvironment(manager: manager, input: input)
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertTrue(result.standardError.contains("HW-SECRET-001"))
            XCTAssertEqual(manager.mutationCount, 0)
        }
    }

    func testUpdateRejectsInvalidMaximumVersionWithoutOverflowOrMutation() throws {
        let manager = TestSecretManager()
        let reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.registry/token"
        )
        manager.seed(reference: reference, value: "existing", version: Int.max)
        let result = HostwrightCLI.run(
            arguments: ["secret", "update", reference.rawValue, "--json"],
            environment: secretEnvironment(
                manager: manager,
                input: SecretInputBox("replacement")
            )
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertTrue(result.standardError.contains("HW-SECRET-001"))
        XCTAssertEqual(manager.mutationCount, 0)
    }

    func testAmbiguousKeychainEffectLeavesRedactedInterruptedRecoveryRecord() throws {
        try withSecureTemporaryDirectory { directory in
            let statePath = directory.appendingPathComponent("state.sqlite").path
            let manager = TestSecretManager()
            manager.nextMutationError = .partialEffect(
                "Injected ambiguous Keychain effect for keychain://[REDACTED]."
            )
            let result = HostwrightCLI.run(
                arguments: [
                    "secret", "create", "keychain://hostwright.registry/token",
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: secretEnvironment(
                    manager: manager,
                    input: SecretInputBox("must-not-persist")
                )
            )

            XCTAssertEqual(
                result.exitCode,
                CLIExitCode.partialFailure.rawValue
            )
            XCTAssertTrue(result.standardError.contains("HW-SECRET-007"))
            XCTAssertFalse(result.standardError.contains("must-not-persist"))

            let store = SQLiteStateStore(path: statePath)
            let group = try XCTUnwrap(
                try store.operationGroups.loadAll().first
            )
            XCTAssertEqual(group.status, .interrupted)
            XCTAssertEqual(group.checkpoint, "keychain-effect-ambiguous")
            let verification = try jsonObject(group.verificationJSONRedacted)
            XCTAssertEqual(verification["status"] as? String, "interrupted")
            XCTAssertEqual(verification["errorCode"] as? String, "HW-SECRET-007")
            XCTAssertFalse(group.intentJSONRedacted.contains("must-not-persist"))
            XCTAssertFalse(group.metadataJSONRedacted.contains("must-not-persist"))
            let persisted = try Data(contentsOf: URL(fileURLWithPath: statePath))
            XCTAssertNil(persisted.range(of: Data("must-not-persist".utf8)))
        }
    }

    func testRejectedKeychainEffectLeavesTerminalFailedVerification() throws {
        try withSecureTemporaryDirectory { directory in
            let statePath = directory.appendingPathComponent("state.sqlite").path
            let manager = TestSecretManager()
            manager.nextMutationError = .permissionDenied(
                "Keychain denied access to keychain://[REDACTED]."
            )
            let result = HostwrightCLI.run(
                arguments: [
                    "secret", "create", "keychain://hostwright.registry/token",
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: secretEnvironment(
                    manager: manager,
                    input: SecretInputBox("must-not-persist")
                )
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.unsafeOperation.rawValue)
            XCTAssertTrue(result.standardError.contains("HW-SECRET-005"))

            let store = SQLiteStateStore(path: statePath)
            let group = try XCTUnwrap(try store.operationGroups.loadAll().first)
            XCTAssertEqual(group.status, .failed)
            XCTAssertEqual(group.checkpoint, "keychain-effect-rejected")
            let verification = try jsonObject(group.verificationJSONRedacted)
            XCTAssertEqual(verification["status"] as? String, "failed")
            XCTAssertEqual(verification["errorCode"] as? String, "HW-SECRET-005")
            XCTAssertFalse(group.verificationJSONRedacted.contains("must-not-persist"))
        }
    }

    func testActiveMutationForSameReferenceBlocksDifferentMutationDurably() throws {
        try withSecureTemporaryDirectory { directory in
            let statePath = directory.appendingPathComponent("state.sqlite").path
            let store = SQLiteStateStore(path: statePath)
            try store.migrate()
            let reference = try HostwrightSecretReference.parse(
                "keychain://hostwright.registry/token"
            )
            let referenceSHA256 = SHA256.hash(data: Data(reference.rawValue.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let operationID = HostwrightResourceUUID.generate()
            let timestamp = "2026-07-24T00:00:00Z"
            let existing = OperationGroupRecord(
                id: operationID,
                operationID: operationID,
                groupKind: "secret-mutation",
                projectID: nil,
                serviceName: nil,
                plannedActionType: "delete",
                status: .active,
                groupIdempotencyKey: "secret:\(referenceSHA256)",
                planHash: String(repeating: "a", count: 64),
                checkpoint: "intent-persisted",
                lockOwner: "hostwright-cli:\(operationID)",
                lockExpiresAt: "9999-01-01T00:00:00Z",
                rollbackAvailable: false,
                manualRecoveryHintRedacted: "Inspect managed Keychain metadata.",
                createdAt: timestamp,
                updatedAt: timestamp,
                metadataJSONRedacted: "{}",
                fencingToken: HostwrightResourceUUID.generate(),
                intentJSONRedacted: "{}",
                compensationJSONRedacted: "[]",
                verificationJSONRedacted: #"{"status":"pending"}"#
            )
            XCTAssertNotNil(try store.operationGroups.acquire(existing).acquired)

            let manager = TestSecretManager()
            let result = HostwrightCLI.run(
                arguments: [
                    "secret", "create", reference.rawValue,
                    "--state-db", statePath,
                    "--output", "json"
                ],
                environment: secretEnvironment(
                    manager: manager,
                    input: SecretInputBox("must-not-reach-keychain")
                )
            )

            XCTAssertEqual(result.exitCode, CLIExitCode.partialFailure.rawValue)
            XCTAssertTrue(result.standardError.contains("HW-SECRET-004"))
            XCTAssertEqual(manager.mutationCount, 0)
            let groups = try store.operationGroups.loadAll()
            XCTAssertEqual(groups, [existing])
            XCTAssertFalse(groups[0].groupIdempotencyKey.contains(reference.rawValue))
        }
    }

    private func secretEnvironment(
        manager: TestSecretManager,
        input: SecretInputBox
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in throw CocoaError(.fileReadNoSuchFile) },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            secretManager: { manager },
            readSecretInput: { input.data },
            swiftVersion: { "Swift 6.3.3" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS 26" }
        )
    }

    private func withSecureTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostwright-secret-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
    }
}

private final class SecretInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Data

    init(_ value: String) {
        self.storage = Data(value.utf8)
    }

    init(data: Data) {
        self.storage = data
    }

    var value: String {
        get {
            lock.withLock { String(decoding: storage, as: UTF8.self) }
        }
        set {
            lock.withLock { storage = Data(newValue.utf8) }
        }
    }

    var data: Data {
        lock.withLock { storage }
    }
}

private final class TestSecretManager: SecretManager, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostwrightSecretReference: (String, SecretMetadata)] = [:]
    private(set) var mutationCount = 0
    var nextMutationError: SecretStoreError?

    func seed(
        reference: HostwrightSecretReference,
        value: String,
        version: Int,
        itemID: UUID = UUID()
    ) {
        lock.withLock {
            let timestamp = Date(timeIntervalSince1970: 1)
            values[reference] = (
                value,
                SecretMetadata(
                    reference: reference,
                    itemID: itemID,
                    version: version,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    accessibility: .whenUnlockedThisDeviceOnly,
                    synchronizable: false
                )
            )
        }
    }

    func readString(reference: HostwrightSecretReference) throws -> String {
        try lock.withLock {
            guard let value = values[reference]?.0 else {
                throw SecretStoreError.notFound("Secret was not found.")
            }
            return value
        }
    }

    func create(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        itemID: UUID
    ) throws -> SecretMetadata {
        try lock.withLock {
            if let nextMutationError {
                self.nextMutationError = nil
                mutationCount += 1
                throw nextMutationError
            }
            guard values[reference] == nil else {
                throw SecretStoreError.duplicate("Secret already exists.")
            }
            mutationCount += 1
            let timestamp = Date(timeIntervalSince1970: 1)
            let metadata = SecretMetadata(
                reference: reference,
                itemID: itemID,
                version: 1,
                createdAt: timestamp,
                updatedAt: timestamp,
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            )
            values[reference] = (
                try String(data: value.data, encoding: .utf8).unwrap(),
                metadata
            )
            return metadata
        }
    }

    func update(
        reference: HostwrightSecretReference,
        value: HostwrightSecretValue,
        expectedItemID: UUID
    ) throws -> SecretMetadata {
        try lock.withLock {
            if let nextMutationError {
                self.nextMutationError = nil
                mutationCount += 1
                throw nextMutationError
            }
            guard let existing = values[reference] else {
                throw SecretStoreError.notFound("Secret was not found.")
            }
            guard existing.1.itemID == expectedItemID else {
                throw SecretStoreError.concurrentMutation(
                    "Secret changed concurrently."
                )
            }
            mutationCount += 1
            let metadata = SecretMetadata(
                reference: reference,
                itemID: existing.1.itemID,
                version: existing.1.version + 1,
                createdAt: existing.1.createdAt,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(existing.1.version + 1)),
                accessibility: .whenUnlockedThisDeviceOnly,
                synchronizable: false
            )
            values[reference] = (
                try String(data: value.data, encoding: .utf8).unwrap(),
                metadata
            )
            return metadata
        }
    }

    func listMetadata() throws -> [SecretMetadata] {
        lock.withLock {
            values.values.map(\.1).sorted {
                $0.reference.rawValue < $1.reference.rawValue
            }
        }
    }

    func check(reference: HostwrightSecretReference) throws -> SecretMetadata {
        try lock.withLock {
            guard let metadata = values[reference]?.1 else {
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
            if let nextMutationError {
                self.nextMutationError = nil
                mutationCount += 1
                throw nextMutationError
            }
            guard let existing = values[reference] else {
                throw SecretStoreError.notFound("Secret was not found.")
            }
            guard existing.1.itemID == expectedItemID else {
                throw SecretStoreError.concurrentMutation(
                    "Secret changed concurrently."
                )
            }
            values.removeValue(forKey: reference)
            mutationCount += 1
        }
    }
}

private extension Optional where Wrapped == String {
    func unwrap() throws -> String {
        guard let self else {
            throw SecretStoreError.invalidValue("Secret was not UTF-8.")
        }
        return self
    }
}
