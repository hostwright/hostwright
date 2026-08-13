import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightObservability
@testable import HostwrightState

final class SupportBundleCLIIntegrationTests: XCTestCase {
    func testOSLogPlatformTimestampNormalizationIsStrictAndCanonical() {
        XCTAssertEqual(
            SupportBundleOSLogCollector.normalizedTimestamp("2026-08-02 04:28:08.294693-0400"),
            "2026-08-02T08:28:08Z"
        )
        XCTAssertNil(SupportBundleOSLogCollector.normalizedTimestamp("not-a-platform-timestamp"))
        XCTAssertNil(SupportBundleOSLogCollector.normalizedTimestamp("2026-08-02T08:28:08Z"))
        XCTAssertTrue(SupportBundleOSLogCollector.isSupportInvocationLog(
            category: "cli",
            message: "version=1 outcome=started command=\"diagnostics\""
        ))
        XCTAssertFalse(SupportBundleOSLogCollector.isSupportInvocationLog(
            category: "daemon",
            message: "version=1 outcome=started command=\"diagnostics\""
        ))
        XCTAssertFalse(SupportBundleOSLogCollector.isSupportInvocationLog(
            category: "cli",
            message: "version=1 outcome=started command=\"metrics\""
        ))
    }

    func testParserPreservesDiagnosticsV1AndAcceptsOnlyLockedSupportSurface() throws {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "diagnostics", "--state-db", "/tmp/state.sqlite", "--bundle", "/tmp/diagnostics.json"
            ]),
            .diagnostics(
                stateDatabasePath: "/tmp/state.sqlite",
                bundlePath: "/tmp/diagnostics.json",
                projectName: nil,
                manifestPath: nil
            )
        )
        XCTAssertEqual(
            try CLICommand.parse(arguments: [
                "diagnostics", "support", "create", "--state-db", "/tmp/state.sqlite",
                "--output-path", "/tmp/support.json", "--confirm-preview", digest,
                "--encrypt-recipient", "support@example.test", "--output", "json"
            ]),
            .supportBundle(options: SupportBundleCLIOptions(
                action: .create(
                    outputPath: "/tmp/support.json",
                    confirmationSHA256: digest,
                    recipientReference: "support@example.test"
                ),
                stateDatabasePath: "/tmp/state.sqlite",
                projectName: nil,
                manifestPath: nil,
                output: .json
            ))
        )
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["diagnostics", "support"]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "diagnostics", "support", "create", "--output-path", "/tmp/support.json"
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "diagnostics", "support", "delete", "--bundle", "/tmp/support.json",
            "--confirm-bundle", digest, "--manifest", "hostwright.yaml"
        ]))
        XCTAssertThrowsError(try CLICommand.parse(arguments: [
            "diagnostics", "support", "preview", "--state-db", "/tmp/a", "--state-db", "/tmp/b"
        ]))
    }

    func testDomainFailuresExposeStableStructuredSupportCodes() throws {
        try withStore { root, store in
            let environment = fixedEnvironment()
            let preview = try supportPreview(store: store, environment: environment)
            let result = HostwrightCLI.run(arguments: [
                "diagnostics", "support", "create",
                "--state-db", store.path,
                "--output-path", root.appendingPathComponent("invalid.cms").path,
                "--confirm-preview", preview.previewSHA256,
                "--encrypt-recipient", "invalid\nrecipient",
                "--output", "json"
            ], environment: environment)
            XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
            XCTAssertTrue(result.standardOutput.isEmpty)
            XCTAssertTrue(result.standardError.contains("\"code\":\"HW-SUPPORT-006\""))
            XCTAssertFalse(result.standardError.contains("HW-CLI-005"))
        }
    }

    func testPreviewCreateAndReceiptProvenDeleteAreBoundedPrivateAndSecretFree() throws {
        try withStore { root, store in
            try seedSensitiveRecords(store)
            var environment = fixedEnvironment()
            environment.supportLogs = {
                HostwrightSupportLogCollection(
                    availability: .available,
                    records: [
                        HostwrightSupportLogRecord(
                            timestamp: "2026-08-01T12:00:00Z",
                            category: "cli",
                            messageType: "Info",
                            messageRedacted: "Authorization: Bearer support-secret-sentinel"
                        ),
                        HostwrightSupportLogRecord(
                            timestamp: "2026-08-01T12:00:01Z",
                            category: "cli",
                            messageType: "Info",
                            messageRedacted: "operator@example.test"
                        ),
                        HostwrightSupportLogRecord(
                            timestamp: "2026-08-01T12:00:02Z",
                            category: "cli",
                            messageType: "Info",
                            messageRedacted: "/private/tmp/operator-path"
                        ),
                        HostwrightSupportLogRecord(
                            timestamp: "2026-08-01T12:00:03Z",
                            category: "cli",
                            messageType: "Info",
                            messageRedacted: "peer=192.0.2.42"
                        )
                    ],
                    droppedRecords: 0
                )
            }
            let preview = try supportPreview(store: store, environment: environment)
            XCTAssertEqual(preview.schemaVersion, 1)
            XCTAssertEqual(preview.sections.map(\.name), [
                "versions", "capabilities", "configuration", "stateIntegrity", "logs",
                "events", "metrics", "traces", "operations", "evidence"
            ])
            XCTAssertLessThanOrEqual(
                preview.estimatedPlaintextBytes,
                HostwrightSupportBundleContract.maximumPlaintextBytes
            )

            let outputPath = root.appendingPathComponent("support-v1.json").path
            let create = try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .create(
                        outputPath: outputPath,
                        confirmationSHA256: preview.previewSHA256,
                        recipientReference: nil
                    ),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            )
            let receipt = try JSONDecoder().decode(
                HostwrightSupportBundleReceipt.self,
                from: Data(create.standardOutput.utf8)
            )
            XCTAssertEqual(receipt.bundleID, preview.bundleID)
            XCTAssertFalse(receipt.encrypted)
            XCTAssertFalse(receipt.automaticUpload)
            let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
            XCTAssertEqual(sha256(data), receipt.outputSHA256)
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(atPath: outputPath)[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.contains("support-secret-sentinel"))
            XCTAssertFalse(text.contains("private-project-name"))
            XCTAssertFalse(text.contains("private-service-name"))
            XCTAssertFalse(text.contains("/Users/private/credential-store"))
            let decoded = try JSONDecoder().decode(HostwrightSupportBundle.self, from: data)
            XCTAssertEqual(decoded.previewSHA256, preview.previewSHA256)
            XCTAssertEqual(decoded.content.events.count, 1)
            XCTAssertEqual(decoded.content.operations.count, 1)
            XCTAssertEqual(decoded.content.logs.map(\.messageRedacted), [
                "redacted", "redacted", "redacted", "redacted"
            ])

            let deletion = try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .delete(bundlePath: outputPath, confirmationSHA256: receipt.outputSHA256),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            )
            let deleted = try JSONDecoder().decode(
                HostwrightSupportBundleDeletionReceipt.self,
                from: Data(deletion.standardOutput.utf8)
            )
            XCTAssertTrue(deleted.deleted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
            XCTAssertEqual(
                try store.events.count(
                    type: HostwrightSupportBundleContract.createdEventType,
                    source: HostwrightSupportBundleContract.source,
                    payloadContains: receipt.bundleID
                ),
                1
            )
            XCTAssertEqual(
                try store.events.count(
                    type: HostwrightSupportBundleContract.deletedEventType,
                    source: HostwrightSupportBundleContract.source,
                    payloadContains: receipt.bundleID
                ),
                1
            )
        }
    }

    func testStaleCancellationUnsafePathsAndUnownedDeletionLeaveNoOwnedArtifact() throws {
        try withStore { root, store in
            var environment = fixedEnvironment()
            let preview = try supportPreview(store: store, environment: environment)
            let stale = root.appendingPathComponent("stale.json").path
            XCTAssertThrowsError(try create(
                store: store,
                outputPath: stale,
                previewSHA256: String(repeating: "0", count: 64),
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: stale))

            environment.supportCancelled = { true }
            let cancelled = root.appendingPathComponent("cancelled.json").path
            XCTAssertThrowsError(try create(
                store: store,
                outputPath: cancelled,
                previewSHA256: preview.previewSHA256,
                environment: environment
            )) { error in
                XCTAssertEqual(error as? HostwrightSupportBundleError, .cancelled)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled))

            environment.supportCancelled = { false }
            let linked = root.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
            let linkedOutput = linked.appendingPathComponent("support.json").path
            XCTAssertThrowsError(try create(
                store: store,
                outputPath: linkedOutput,
                previewSHA256: preview.previewSHA256,
                environment: environment
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("support.json").path
            ))

            let unrelated = root.appendingPathComponent("unrelated.json").path
            try Data("unrelated".utf8).write(to: URL(fileURLWithPath: unrelated))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unrelated)
            let unrelatedSHA = sha256(try Data(contentsOf: URL(fileURLWithPath: unrelated)))
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .delete(bundlePath: unrelated, confirmationSHA256: unrelatedSHA),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
            let status = try StateSupportBundleEvidenceService(store: store).status()
            XCTAssertFalse(status.pendingRecovery)
        }
    }

    func testCreateRefusesOverwriteAndDeleteRefusesHardLinkedOwnedBundle() throws {
        try withStore { root, store in
            let environment = fixedEnvironment()
            let preview = try supportPreview(store: store, environment: environment)
            let preexisting = root.appendingPathComponent("preexisting.json")
            let sentinel = Data("operator-owned".utf8)
            try sentinel.write(to: preexisting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: preexisting.path
            )
            XCTAssertThrowsError(try create(
                store: store,
                outputPath: preexisting.path,
                previewSHA256: preview.previewSHA256,
                environment: environment
            ))
            XCTAssertEqual(try Data(contentsOf: preexisting), sentinel)

            let output = root.appendingPathComponent("owned.json")
            let createResult = try create(
                store: store,
                outputPath: output.path,
                previewSHA256: preview.previewSHA256,
                environment: environment
            )
            let receipt = try JSONDecoder().decode(
                HostwrightSupportBundleReceipt.self,
                from: Data(createResult.standardOutput.utf8)
            )
            let additionalLink = root.appendingPathComponent("additional-link.json")
            try FileManager.default.linkItem(at: output, to: additionalLink)
            XCTAssertThrowsError(try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .delete(
                        bundlePath: output.path,
                        confirmationSHA256: receipt.outputSHA256
                    ),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            ))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: additionalLink.path))
            XCTAssertFalse(try StateSupportBundleEvidenceService(store: store).status().pendingRecovery)

            try FileManager.default.removeItem(at: additionalLink)
            _ = try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .delete(
                        bundlePath: output.path,
                        confirmationSHA256: receipt.outputSHA256
                    ),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testPostPersistReplacementIsRefusedWithoutDeletingTheSubstitute() throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("replaced.json")
        let substitute = Data("substitute-operator-file".utf8)
        XCTAssertThrowsError(try SecureLocalExportWriter.write(
            Data("hostwright-output".utf8),
            to: output.path,
            maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
            isCancelled: { false },
            unsafeError: HostwrightSupportBundleError.unsafeOutputPath,
            onPersist: { _ in
                try FileManager.default.removeItem(at: output)
                try substitute.write(to: output)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: output.path
                )
            }
        )) { error in
            XCTAssertEqual(error as? HostwrightSupportBundleError, .unsafeOutputPath)
        }
        XCTAssertEqual(try Data(contentsOf: output), substitute)
    }

    func testDurableJournalRecoversWrittenCreationAndConfirmedDeletionAcrossRestart() throws {
        try withStore { root, store in
            let path = root.appendingPathComponent("interrupted.json").path
            let content = Data("{\"kind\":\"hostwright.support-bundle\"}".utf8)
            let previewSHA = String(repeating: "a", count: 64)
            let bundleID = "support-" + String(repeating: "b", count: 32)
            var service = try StateSupportBundleEvidenceService(store: store)
            let createID = try service.beginCreation(
                bundleID: bundleID,
                previewSHA256: previewSHA,
                outputPath: path,
                encrypted: false,
                recipientReferenceSHA256: nil
            )
            _ = try SecureLocalExportWriter.write(
                content,
                to: path,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                isCancelled: { false },
                unsafeError: HostwrightSupportBundleError.unsafeOutputPath,
                onPersist: { identity in
                    try service.recordCreatedFile(operationID: createID, identity: identity)
                }
            )

            service = try StateSupportBundleEvidenceService(store: SQLiteStateStore(path: store.path))
            let creationRecovery = try service.recover(
                inspect: { try SecureLocalExportWriter.inspect(
                    $0,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                ) },
                delete: { _, _ in XCTFail("Creation recovery must not delete a proven output.") }
            )
            XCTAssertEqual(creationRecovery.action, "finalized-create")
            let identity = try XCTUnwrap(SecureLocalExportWriter.inspect(
                path,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
            ))
            let deletion = try service.beginDeletion(
                outputPath: path,
                expectedSHA256: identity.sha256,
                identity: identity
            )
            try SecureLocalExportWriter.delete(
                path,
                expectedIdentity: identity,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                isCancelled: { false },
                unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
            )
            service = try StateSupportBundleEvidenceService(store: SQLiteStateStore(path: store.path))
            let deletionRecovery = try service.recover(
                inspect: { try SecureLocalExportWriter.inspect(
                    $0,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                ) },
                delete: { _, _ in XCTFail("Absent-file recovery must not issue a second delete.") }
            )
            XCTAssertEqual(deletionRecovery.action, "finalized-delete")
            XCTAssertEqual(deletion.bundleID, bundleID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(try service.status().pendingRecovery)
        }
    }

    func testRecoverySafeHoldsWhenWrittenOutputIdentityChanges() throws {
        try withStore { root, store in
            let path = root.appendingPathComponent("identity-changed.json").path
            let original = Data("{\"kind\":\"hostwright.support-bundle\"}".utf8)
            var service = try StateSupportBundleEvidenceService(store: store)
            let operationID = try service.beginCreation(
                bundleID: "support-" + String(repeating: "b", count: 32),
                previewSHA256: String(repeating: "a", count: 64),
                outputPath: path,
                encrypted: false,
                recipientReferenceSHA256: nil
            )
            _ = try SecureLocalExportWriter.write(
                original,
                to: path,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                isCancelled: { false },
                unsafeError: HostwrightSupportBundleError.unsafeOutputPath,
                onPersist: { identity in
                    try service.recordCreatedFile(operationID: operationID, identity: identity)
                }
            )
            try FileManager.default.removeItem(atPath: path)
            try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

            service = try StateSupportBundleEvidenceService(store: SQLiteStateStore(path: store.path))
            let recovery = try service.recover(
                inspect: { try SecureLocalExportWriter.inspect(
                    $0,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                ) },
                delete: { _, _ in XCTFail("An identity mismatch must never be deleted.") }
            )
            XCTAssertTrue(recovery.safeHold)
            XCTAssertEqual(recovery.action, "safe-hold")
            XCTAssertTrue(try service.status().pendingRecovery)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("changed".utf8))
        }
    }

    func testInjectedEncryptionNeverWritesPlaintextAndUsesOnlyRecipientHashEvidence() throws {
        try withStore { root, store in
            var environment = fixedEnvironment()
            let preview = try supportPreview(store: store, environment: environment)
            environment.supportEncrypt = { data, recipient in
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                return Data("cms-v1:\(recipient):\(digest)".utf8)
            }
            let path = root.appendingPathComponent("support.cms").path
            let result = try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .create(
                        outputPath: path,
                        confirmationSHA256: preview.previewSHA256,
                        recipientReference: "support@example.test"
                    ),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            )
            let receipt = try JSONDecoder().decode(
                HostwrightSupportBundleReceipt.self,
                from: Data(result.standardOutput.utf8)
            )
            XCTAssertTrue(receipt.encrypted)
            XCTAssertNotNil(receipt.recipientReferenceSHA256)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasPrefix("cms-v1:"))
            let event = try store.events.loadAll().last {
                $0.type == HostwrightSupportBundleContract.createdEventType
            }
            XCTAssertNotNil(event)
            XCTAssertFalse(event?.payloadJSONRedacted.contains("support@example.test") ?? true)
        }
    }

    func testPlatformCMSUsesDisposableKeychainCertificateAndDecryptsExactPlaintext() throws {
        let root = try privateRoot()
        let keychainPath = root.appendingPathComponent("qualification.keychain-db").path
        let keyPath = root.appendingPathComponent("recipient-key.pem").path
        let certificatePath = root.appendingPathComponent("recipient-cert.pem").path
        let recipient = "hostwright-p08-\(UUID().uuidString.lowercased())@example.test"
        defer {
            _ = try? runSecure("/usr/bin/security", ["delete-keychain", keychainPath], root: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(try runSecure(
            "/usr/bin/openssl",
            [
                "req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath,
                "-out", certificatePath, "-nodes", "-days", "1",
                "-subj", "/CN=Hostwright Phase08/emailAddress=\(recipient)"
            ],
            root: root.path
        ).exitStatus, 0)
        XCTAssertEqual(try runSecure(
            "/usr/bin/security",
            ["create-keychain", "-p", "", keychainPath],
            root: root.path
        ).exitStatus, 0)
        XCTAssertEqual(try runSecure(
            "/usr/bin/security",
            ["unlock-keychain", "-p", "", keychainPath],
            root: root.path
        ).exitStatus, 0)
        XCTAssertEqual(try runSecure(
            "/usr/bin/security",
            ["import", certificatePath, "-k", keychainPath, "-t", "cert"],
            root: root.path
        ).exitStatus, 0)

        let plaintext = Data("hostwright-platform-cms-v1".utf8)
        let encrypted = try SupportBundlePlatformEncryptor.encrypt(
            plaintext,
            recipientReference: recipient,
            keychainPath: keychainPath
        )
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertNotEqual(encrypted, plaintext)
        let decrypted = try runSecure(
            "/usr/bin/openssl",
            [
                "cms", "-decrypt", "-inform", "DER", "-recip", certificatePath,
                "-inkey", keyPath
            ],
            root: root.path,
            input: encrypted
        )
        XCTAssertEqual(decrypted.exitStatus, 0)
        XCTAssertEqual(decrypted.standardOutput, plaintext)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("plaintext.json").path
        ))
    }

    func testManifestInventoryExportsShapeOnlyWithoutNamesImagesCommandsOrProbeDetails() throws {
        try withStore { root, store in
            let manifest = root.appendingPathComponent("private-manifest.yaml")
            let manifestText = """
            version: 2
            project: private-project-name
            imagePolicy: require-digest
            services:
              private-service-name:
                image: docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92
                command: ["python3", "-m", "http.server", "8080"]
                ports: ["18080:8080"]
                probes:
                  startup:
                    exec: ["python3", "-c", "raise SystemExit(0)"]
                  readiness:
                    tcp:
                      port: 8080
                  liveness:
                    http:
                      port: 8080
                      path: /private-health-path
                restart:
                  policy: unless-stopped
                update:
                  strategy: recreate
                  maxSurge: 0
                  maxUnavailable: 1
                  progressDeadline: 60s
            """
            try Data(manifestText.utf8).write(to: manifest)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            let environment = fixedEnvironment()
            let preview = try supportPreview(
                store: store,
                environment: environment,
                manifestPath: manifest.path
            )
            let output = root.appendingPathComponent("shape-only.json")
            let createResult = try create(
                store: store,
                outputPath: output.path,
                previewSHA256: preview.previewSHA256,
                environment: environment,
                manifestPath: manifest.path
            )
            let receipt = try JSONDecoder().decode(
                HostwrightSupportBundleReceipt.self,
                from: Data(createResult.standardOutput.utf8)
            )
            let bytes = try Data(contentsOf: output)
            let bundle = try JSONDecoder().decode(HostwrightSupportBundle.self, from: bytes)
            XCTAssertEqual(bundle.content.configuration.serviceCount, 1)
            XCTAssertEqual(bundle.content.configuration.healthProbeCount, 3)
            XCTAssertEqual(bundle.content.configuration.publishedPortCount, 1)
            XCTAssertTrue(bundle.content.configuration.hasRestartPolicy)
            XCTAssertTrue(bundle.content.configuration.hasRolloutPolicy)
            let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
            XCTAssertFalse(text.contains("private-project-name"))
            XCTAssertFalse(text.contains("private-service-name"))
            XCTAssertFalse(text.contains("docker.io"))
            XCTAssertFalse(text.contains("http.server"))
            XCTAssertFalse(text.contains("private-health-path"))

            _ = try HostwrightCLI.run(
                command: .supportBundle(options: SupportBundleCLIOptions(
                    action: .delete(
                        bundlePath: output.path,
                        confirmationSHA256: receipt.outputSHA256
                    ),
                    stateDatabasePath: store.path,
                    projectName: nil,
                    manifestPath: nil,
                    output: .json
                )),
                environment: environment
            )
        }
    }

    private func supportPreview(
        store: SQLiteStateStore,
        environment: CLIEnvironment,
        manifestPath: String? = nil
    ) throws -> HostwrightSupportBundlePreview {
        let result = try HostwrightCLI.run(
            command: .supportBundle(options: SupportBundleCLIOptions(
                action: .preview,
                stateDatabasePath: store.path,
                projectName: nil,
                manifestPath: manifestPath,
                output: .json
            )),
            environment: environment
        )
        return try JSONDecoder().decode(
            HostwrightSupportBundlePreview.self,
            from: Data(result.standardOutput.utf8)
        )
    }

    private func create(
        store: SQLiteStateStore,
        outputPath: String,
        previewSHA256: String,
        environment: CLIEnvironment,
        manifestPath: String? = nil
    ) throws -> CLIRunResult {
        try HostwrightCLI.run(
            command: .supportBundle(options: SupportBundleCLIOptions(
                action: .create(
                    outputPath: outputPath,
                    confirmationSHA256: previewSHA256,
                    recipientReference: nil
                ),
                stateDatabasePath: store.path,
                projectName: nil,
                manifestPath: manifestPath,
                output: .json
            )),
            environment: environment
        )
    }

    private func seedSensitiveRecords(_ store: SQLiteStateStore) throws {
        try store.events.append([EventRecord(
            id: "private-event-id",
            timestamp: "2026-08-01T11:59:00Z",
            severity: .error,
            type: "lifecycle.failed",
            source: "test",
            projectID: nil,
            serviceName: nil,
            runtimeAdapter: nil,
            message: "support-secret-sentinel /Users/private/credential-store",
            payloadJSONRedacted: "{\"token\":\"support-secret-sentinel\"}"
        )])
        try store.operations.record(OperationRecord(
            id: "private-operation-id",
            createdAt: "2026-08-01T11:58:00Z",
            updatedAt: "2026-08-01T11:59:00Z",
            plannedActionType: "up",
            projectID: nil,
            serviceName: nil,
            status: .failed,
            idempotencyKey: "support-secret-sentinel",
            planHash: String(repeating: "c", count: 64),
            payloadJSONRedacted: "{\"path\":\"/Users/private/credential-store\"}"
        ))
    }

    private func fixedEnvironment() -> CLIEnvironment {
        var environment = CLIEnvironment.live
        environment.supportDate = {
            ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
        }
        environment.metricsDate = environment.supportDate
        environment.traceDate = environment.supportDate
        environment.supportLogs = {
            HostwrightSupportLogCollection(availability: .available, records: [], droppedRecords: 0)
        }
        return environment
    }

    private func withStore(_ body: (URL, SQLiteStateStore) throws -> Void) throws {
        let root = try privateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(root, store)
    }

    private func runSecure(
        _ executable: String,
        _ arguments: [String],
        root: String,
        input: Data? = nil
    ) throws -> SecureSubprocessResult {
        try SecureSubprocessRunner().run(SecureSubprocessRequest(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: root,
            standardInput: input,
            timeoutMilliseconds: 30_000,
            maximumStandardOutputBytes: 1 * 1_024 * 1_024,
            maximumStandardErrorBytes: 1 * 1_024 * 1_024,
            maximumStandardInputBytes: 1 * 1_024 * 1_024
        ))
    }

    private func privateRoot() throws -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporary = temporaryPath.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporaryPath, isDirectory: true)
            : URL(fileURLWithPath: temporaryPath, isDirectory: true)
        let root = canonicalTemporary
            .appendingPathComponent("hostwright-support-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
