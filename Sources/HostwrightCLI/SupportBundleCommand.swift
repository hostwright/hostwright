import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightObservability
import HostwrightRuntime
import HostwrightState

struct SupportBundleCommandRunner {
    let options: SupportBundleCLIOptions
    let stateStoreConfiguration: StateStoreConfiguration
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        let store = SQLiteStateStore(configuration: stateStoreConfiguration)
        let evidence = try StateSupportBundleEvidenceService(store: store, date: environment.supportDate)
        switch options.action {
        case .status:
            let status = try evidence.status()
            return result(status, text: render(status))
        case .preview:
            let build = try build(store: store)
            return result(build.preview, text: render(build.preview))
        case .create(let outputPath, let confirmationSHA256, let recipientReference):
            let build = try build(store: store)
            guard build.preview.previewSHA256 == confirmationSHA256 else {
                throw HostwrightSupportBundleError.previewChanged
            }
            guard !environment.supportCancelled() else {
                throw HostwrightSupportBundleError.cancelled
            }
            var output = build.bundleData
            var recipientSHA256: String?
            if let recipientReference {
                guard HostwrightSupportBundleContract.isValidRecipientReference(recipientReference) else {
                    throw HostwrightSupportBundleError.invalidRecipientReference
                }
                recipientSHA256 = sha256(Data(recipientReference.utf8))
                output = try environment.supportEncrypt(output, recipientReference)
                guard !output.isEmpty,
                      output.count <= HostwrightSupportBundleContract.maximumEncryptedBytes else {
                    throw HostwrightSupportBundleError.encryptionFailed
                }
            }
            guard !environment.supportCancelled() else {
                throw HostwrightSupportBundleError.cancelled
            }
            guard try SecureLocalExportWriter.inspect(
                outputPath,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                unsafeError: HostwrightSupportBundleError.unsafeOutputPath
            ) == nil else {
                throw HostwrightSupportBundleError.unsafeOutputPath
            }
            let operationID = try evidence.beginCreation(
                bundleID: build.preview.bundleID,
                previewSHA256: build.preview.previewSHA256,
                outputPath: outputPath,
                encrypted: recipientReference != nil,
                recipientReferenceSHA256: recipientSHA256
            )
            let written: SecureLocalExportReceipt
            do {
                written = try SecureLocalExportWriter.write(
                    output,
                    to: outputPath,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    isCancelled: environment.supportCancelled,
                    unsafeError: HostwrightSupportBundleError.unsafeOutputPath,
                    onPersist: { identity in
                        try evidence.recordCreatedFile(operationID: operationID, identity: identity)
                    }
                )
            } catch {
                try? evidence.abandonPreparedCreationIfNoEffect(operationID: operationID)
                if isCancellation(error) { throw HostwrightSupportBundleError.cancelled }
                throw error
            }
            guard try SecureLocalExportWriter.inspect(
                outputPath,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
            ) == written.fileIdentity else {
                throw HostwrightSupportBundleError.bundleIdentityChanged
            }
            _ = try evidence.completeCreation(operationID: operationID)
            let receipt = HostwrightSupportBundleReceipt(
                bundleID: build.preview.bundleID,
                previewSHA256: build.preview.previewSHA256,
                outputPath: outputPath,
                outputSHA256: written.outputSHA256,
                outputBytes: written.outputBytes,
                encrypted: recipientReference != nil,
                recipientReferenceSHA256: recipientSHA256
            )
            return result(receipt, text: render(receipt))
        case .delete(let bundlePath, let confirmationSHA256):
            guard HostwrightSupportBundleContract.isValidSHA256(confirmationSHA256) else {
                throw HostwrightSupportBundleError.invalidContract
            }
            guard let identity = try SecureLocalExportWriter.inspect(
                bundlePath,
                maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
            ), identity.sha256 == confirmationSHA256 else {
                throw HostwrightSupportBundleError.bundleIdentityChanged
            }
            let prepared = try evidence.beginDeletion(
                outputPath: bundlePath,
                expectedSHA256: confirmationSHA256,
                identity: identity
            )
            do {
                try SecureLocalExportWriter.delete(
                    bundlePath,
                    expectedIdentity: identity,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    isCancelled: environment.supportCancelled,
                    unsafeError: HostwrightSupportBundleError.bundleIdentityChanged,
                    onDeleted: {
                        try evidence.recordDeletedFile(operationID: prepared.operationID)
                    }
                )
            } catch {
                if let observed = try? SecureLocalExportWriter.inspect(
                    bundlePath,
                    maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                    unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                ) {
                    try? evidence.abandonPreparedDeletionIfUnchanged(
                        operationID: prepared.operationID,
                        observedIdentity: observed
                    )
                }
                if isCancellation(error) { throw HostwrightSupportBundleError.cancelled }
                throw error
            }
            _ = try evidence.completeDeletion(operationID: prepared.operationID)
            let receipt = HostwrightSupportBundleDeletionReceipt(
                bundleID: prepared.bundleID,
                outputPath: bundlePath,
                outputSHA256: confirmationSHA256
            )
            return result(receipt, text: render(receipt))
        case .recover:
            guard !environment.supportCancelled() else {
                throw HostwrightSupportBundleError.cancelled
            }
            let recovery: StateSupportBundleRecoveryResult
            do {
                recovery = try evidence.recover(
                    inspect: { path in
                        try SecureLocalExportWriter.inspect(
                            path,
                            maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                            unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                        )
                    },
                    delete: { path, identity in
                        try SecureLocalExportWriter.delete(
                            path,
                            expectedIdentity: identity,
                            maximumBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                            isCancelled: environment.supportCancelled,
                            unsafeError: HostwrightSupportBundleError.bundleIdentityChanged
                        )
                    }
                )
            } catch {
                if isCancellation(error) { throw HostwrightSupportBundleError.cancelled }
                throw error
            }
            if recovery.safeHold { throw HostwrightSupportBundleError.recoverySafeHold }
            return result(recovery, text: render(recovery))
        }
    }

    private func build(store: SQLiteStateStore) throws -> SupportBundleBuild {
        let collectedAt = environment.supportDate()
        let generatedAt = ISO8601DateFormatter().string(from: collectedAt)
        let projectID = options.projectName.map { "project-\($0)" }
        let state = try StateSupportBundleSnapshotService(
            store: store,
            date: { collectedAt }
        ).collect(projectID: projectID)
        let logs = validatedLogs(environment.supportLogs())
        let configuration = try configurationShape()
        let contracts = HostwrightCapabilityCatalog.report.contracts
        let platform = environment.platformSnapshot()
        let versions = HostwrightSupportVersionInventory(
            productVersion: HostwrightIdentity.version,
            releaseTarget: HostwrightIdentity.releaseTarget,
            manifestVersion: contracts.manifest,
            stateSchemaVersion: state.integrity.stateSchemaVersion,
            controlAPIVersion: contracts.controlAPI,
            runtimeProviderAPIVersion: contracts.runtimeProviderAPI,
            storageProviderAPIVersion: contracts.storageProviderAPI,
            networkProviderSPIVersion: contracts.networkProviderSPI,
            operatingSystem: boundedRedacted(environment.operatingSystemDescription(), maximumBytes: 256),
            architecture: boundedRedacted(platform.architecture, maximumBytes: 64),
            swiftVersion: environment.swiftVersion().map { boundedRedacted($0, maximumBytes: 256) }
        )
        let content = HostwrightSupportBundleContent(
            versions: versions,
            capabilities: HostwrightCapabilityCatalog.report,
            configuration: configuration,
            stateIntegrity: state.integrity,
            logs: logs.records,
            events: state.events,
            metrics: state.metrics,
            traces: state.traces,
            operations: state.operations,
            evidence: state.evidence
        )
        let sections = try sectionSummaries(content: content, logs: logs, state: state)
        let confirmation = SupportBundleConfirmation(content: content, sections: sections)
        let previewSHA256 = sha256(try canonicalData(confirmation))
        let bundleID = "support-" + String(previewSHA256.prefix(32))
        let bundle = HostwrightSupportBundle(
            bundleID: bundleID,
            createdAt: generatedAt,
            previewSHA256: previewSHA256,
            content: content,
            sections: sections
        )
        let bundleData = try canonicalData(bundle)
        guard bundleData.count <= HostwrightSupportBundleContract.maximumPlaintextBytes else {
            throw HostwrightSupportBundleError.plaintextLimitExceeded
        }
        let preview = HostwrightSupportBundlePreview(
            generatedAt: generatedAt,
            bundleID: bundleID,
            previewSHA256: previewSHA256,
            estimatedPlaintextBytes: bundleData.count,
            sections: sections
        )
        return SupportBundleBuild(preview: preview, bundleData: bundleData)
    }

    private func configurationShape() throws -> HostwrightSupportConfigurationShape {
        guard let path = options.manifestPath else { return .absent }
        let manifest = try ManifestValidator.validated(environment.readTextFile(path))
        let probeCount = manifest.services.reduce(0) { count, service in
            count + [service.probes.startup, service.probes.readiness, service.probes.liveness]
                .compactMap { $0 }.count + (service.health == nil ? 0 : 1)
        }
        let defaultUpdate = HostwrightUpdatePolicy()
        return HostwrightSupportConfigurationShape(
            manifestProvided: true,
            manifestVersion: manifest.effectiveVersion,
            serviceCount: manifest.services.count,
            healthProbeCount: probeCount,
            storageMountCount: manifest.services.reduce(0) { $0 + $1.mounts.count },
            publishedPortCount: manifest.services.reduce(0) { $0 + $1.publishedPorts.count },
            hasRestartPolicy: manifest.restartBudget != nil || manifest.services.contains { $0.restart != nil },
            hasMaintenancePolicy: manifest.maintenance != nil,
            hasRolloutPolicy: manifest.services.contains { $0.update != defaultUpdate },
            hasRollbackPolicy: false,
            hasRetentionPolicy: manifest.retention != nil,
            hasObservabilityPolicy: false
        )
    }

    private func validatedLogs(_ input: HostwrightSupportLogCollection) -> HostwrightSupportLogCollection {
        var valid: [HostwrightSupportLogRecord] = []
        var dropped = max(0, input.droppedRecords)
        let normalizedAvailability: HostwrightSupportBundleAvailability
        let normalizedReason: String?
        switch (input.availability, input.reasonCode) {
        case (.available, nil):
            normalizedAvailability = .available
            normalizedReason = nil
        case (.unavailable, "HW-SUPPORT-LOGS-UNAVAILABLE"):
            normalizedAvailability = .unavailable
            normalizedReason = "HW-SUPPORT-LOGS-UNAVAILABLE"
        case (.degraded, "HW-SUPPORT-LOGS-DEGRADED"):
            normalizedAvailability = .degraded
            normalizedReason = "HW-SUPPORT-LOGS-DEGRADED"
        default:
            normalizedAvailability = .degraded
            normalizedReason = "HW-SUPPORT-LOGS-DEGRADED"
            dropped += 1
        }
        let formatter = ISO8601DateFormatter()
        for record in input.records {
            guard valid.count < HostwrightSupportBundleContract.maximumLogs,
                  record.timestamp.utf8.count <= 64,
                  formatter.date(from: record.timestamp) != nil,
                  safeLogField(record.category),
                  safeLogField(record.messageType) else {
                dropped += 1
                continue
            }
            valid.append(HostwrightSupportLogRecord(
                timestamp: record.timestamp,
                category: record.category,
                messageType: record.messageType,
                messageRedacted: boundedRedacted(record.messageRedacted, maximumBytes: 2 * 1_024)
            ))
        }
        return HostwrightSupportLogCollection(
            availability: normalizedAvailability,
            records: valid,
            droppedRecords: dropped,
            reasonCode: normalizedReason
        )
    }

    private func sectionSummaries(
        content: HostwrightSupportBundleContent,
        logs: HostwrightSupportLogCollection,
        state: StateSupportBundleSnapshot
    ) throws -> [HostwrightSupportBundleSectionSummary] {
        let inputs: [(String, HostwrightSupportBundleAvailability, Int, Int, String?, any Encodable)] = [
            ("versions", .available, 1, 0, nil, content.versions),
            ("capabilities", .available, content.capabilities.capabilities.count, 0, nil, content.capabilities),
            ("configuration", .available, 1, 0, nil, content.configuration),
            ("stateIntegrity", .available, content.stateIntegrity.checks.count, 0, nil, content.stateIntegrity),
            ("logs", logs.availability, content.logs.count, logs.droppedRecords, logs.reasonCode, content.logs),
            ("events", .available, content.events.count, state.droppedEvents, nil, content.events),
            ("metrics", .available, content.metrics.series.count, 0, nil, content.metrics),
            ("traces", .available, content.traces.count, state.droppedTraces, nil, content.traces),
            ("operations", .available, content.operations.count, state.droppedOperations, nil, content.operations),
            ("evidence", .available, content.evidence.count, state.droppedEvidence, nil, content.evidence)
        ]
        let summaries = try inputs.map { name, availability, records, dropped, reason, value in
            let bytes = try canonicalExistentialData(value).count
            guard bytes <= HostwrightSupportBundleContract.maximumSectionBytes else {
                throw HostwrightSupportBundleError.sectionLimitExceeded
            }
            return HostwrightSupportBundleSectionSummary(
                name: name,
                availability: availability,
                records: records,
                droppedRecords: dropped,
                encodedBytes: bytes,
                reasonCode: reason
            )
        }
        guard summaries.reduce(0, { $0 + $1.encodedBytes }) <=
                HostwrightSupportBundleContract.maximumSectionBytes else {
            throw HostwrightSupportBundleError.sectionLimitExceeded
        }
        return summaries
    }

    private func result<T: Encodable>(_ value: T, text: String) -> CLIRunResult {
        CLIRunResult(standardOutput: options.output == .json ? CLIJSON.codable(value) : text)
    }

    private func render(_ preview: HostwrightSupportBundlePreview) -> String {
        let sections = preview.sections.map {
            "  \($0.name): \($0.availability.rawValue) records=\($0.records) dropped=\($0.droppedRecords) bytes=\($0.encodedBytes)"
        }.joined(separator: "\n")
        return """
        Hostwright support-bundle preview
        Schema: v\(preview.schemaVersion)
        Bundle: \(preview.bundleID)
        Preview SHA-256: \(preview.previewSHA256)
        Estimated plaintext bytes: \(preview.estimatedPlaintextBytes)
        Confirmation required: true
        Automatic upload: false
        Sections:
        \(sections)

        """
    }

    private func render(_ receipt: HostwrightSupportBundleReceipt) -> String {
        """
        Hostwright support bundle
        Schema: v\(receipt.schemaVersion)
        Bundle: \(receipt.bundleID)
        Preview SHA-256: \(receipt.previewSHA256)
        Output: \(receipt.outputPath)
        Output SHA-256: \(receipt.outputSHA256)
        Output bytes: \(receipt.outputBytes)
        Encrypted: \(receipt.encrypted)
        Automatic upload: false
        Ownership: operator-owned

        """
    }

    private func render(_ receipt: HostwrightSupportBundleDeletionReceipt) -> String {
        """
        Hostwright support-bundle deletion
        Bundle: \(receipt.bundleID)
        Output: \(receipt.outputPath)
        Output SHA-256: \(receipt.outputSHA256)
        Deleted: true

        """
    }

    private func render(_ status: StateSupportBundleStatus) -> String {
        """
        Hostwright support-bundle status
        Schema: v\(status.schemaVersion)
        Pending recovery: \(status.pendingRecovery)
        Pending phase: \(status.pendingPhase ?? "none")
        Retained creation receipts: \(status.retainedCreationReceipts)
        Platform encryption: optional Keychain CMS recipient
        Automatic upload: false

        """
    }

    private func render(_ recovery: StateSupportBundleRecoveryResult) -> String {
        """
        Hostwright support-bundle recovery
        Action: \(recovery.action)
        Bundle: \(recovery.bundleID ?? "none")
        Safe hold: \(recovery.safeHold)

        """
    }

    private func safeLogField(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        guard let stateError = error as? StateStoreError else { return false }
        if case .operationCancelled = stateError { return true }
        return false
    }

    private func boundedRedacted(_ value: String, maximumBytes: Int) -> String {
        let redacted = RuntimeRedactionPolicy.default.redact(value)
        let lowered = redacted.lowercased()
        let sensitiveMarkers = [
            "authorization", "bearer ", "password", "passwd", "token=", "token:",
            "secret", "credential", "api_key", "api-key", "private key", "/users/",
            "ssh-", "akia"
        ]
        if sensitiveMarkers.contains(where: lowered.contains) ||
            redacted.range(
                of: "(?i)(gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{16,}|[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}|https?://|(?:^|[[:space:]\"'])/(?:users|private|tmp|var|volumes|applications|library|system|opt|usr|etc|home)/|(?:[0-9]{1,3}\\.){3}[0-9]{1,3})",
                options: .regularExpression
            ) != nil {
            return "redacted"
        }
        let flattened = redacted.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        var output = ""
        var bytes = 0
        for character in flattened {
            let encoded = String(character).utf8.count
            guard bytes + encoded <= maximumBytes else { break }
            output.append(character)
            bytes += encoded
        }
        return output
    }

    private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func canonicalExistentialData(_ value: any Encodable) throws -> Data {
        try canonicalData(AnyEncodable(value))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SupportBundleOSLogCollector {
    static func collect() -> HostwrightSupportLogCollection {
        do {
            let result = try SecureSubprocessRunner().run(SecureSubprocessRequest(
                executablePath: "/usr/bin/log",
                arguments: [
                    "show", "--last", "1h", "--predicate",
                    "subsystem == \"dev.hostwright\"", "--style", "ndjson"
                ],
                workingDirectory: "/",
                timeoutMilliseconds: 10_000,
                maximumStandardOutputBytes: 512 * 1_024,
                maximumStandardErrorBytes: 16 * 1_024
            ))
            guard result.exitStatus == 0,
                  result.terminationSignal == nil,
                  !result.standardOutputTruncated,
                  !result.standardErrorTruncated,
                  let text = String(data: result.standardOutput, encoding: .utf8) else {
                return .unavailable
            }
            var parsed: [HostwrightSupportLogRecord] = []
            var dropped = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard line.utf8.count <= 16 * 1_024,
                      let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let platformTimestamp = object["timestamp"] as? String,
                      let timestamp = normalizedTimestamp(platformTimestamp),
                      let category = object["category"] as? String,
                      let messageType = object["messageType"] as? String,
                      let message = object["eventMessage"] as? String else {
                    dropped += 1
                    continue
                }
                if isSupportInvocationLog(category: category, message: message) {
                    continue
                }
                parsed.append(HostwrightSupportLogRecord(
                    timestamp: timestamp,
                    category: category,
                    messageType: messageType,
                    messageRedacted: RuntimeRedactionPolicy.default.redact(message)
                ))
            }
            let retained = Array(parsed.suffix(HostwrightSupportBundleContract.maximumLogs))
            dropped += max(0, parsed.count - retained.count)
            return HostwrightSupportLogCollection(
                availability: .available,
                records: retained,
                droppedRecords: dropped
            )
        } catch {
            return HostwrightSupportLogCollection(
                availability: .degraded,
                records: [],
                droppedRecords: 0,
                reasonCode: "HW-SUPPORT-LOGS-DEGRADED"
            )
        }
    }

    static func normalizedTimestamp(_ value: String) -> String? {
        let platform = DateFormatter()
        platform.locale = Locale(identifier: "en_US_POSIX")
        platform.calendar = Calendar(identifier: .gregorian)
        platform.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxx"
        guard let date = platform.date(from: value) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    static func isSupportInvocationLog(category: String, message: String) -> Bool {
        category == "cli" && message.contains("command=\"diagnostics\"")
    }
}

enum SupportBundlePlatformEncryptor {
    static func encrypt(
        _ data: Data,
        recipientReference: String,
        keychainPath: String? = nil
    ) throws -> Data {
        guard HostwrightSupportBundleContract.isValidRecipientReference(recipientReference),
              data.count <= HostwrightSupportBundleContract.maximumPlaintextBytes else {
            throw HostwrightSupportBundleError.invalidRecipientReference
        }
        var arguments = ["cms", "-E", "-r", recipientReference]
        if let keychainPath {
            let components = keychainPath.split(separator: "/", omittingEmptySubsequences: true)
            guard keychainPath.hasPrefix("/"), !keychainPath.hasSuffix("/"),
                  !components.isEmpty,
                  components.allSatisfy({ $0 != "." && $0 != ".." }),
                  "/" + components.joined(separator: "/") == keychainPath else {
                throw HostwrightSupportBundleError.encryptionUnavailable
            }
            arguments += ["-k", keychainPath]
        }
        let result: SecureSubprocessResult
        do {
            result = try SecureSubprocessRunner().run(SecureSubprocessRequest(
                executablePath: "/usr/bin/security",
                arguments: arguments,
                workingDirectory: "/",
                standardInput: data,
                timeoutMilliseconds: 30_000,
                maximumStandardOutputBytes: HostwrightSupportBundleContract.maximumEncryptedBytes,
                maximumStandardErrorBytes: 16 * 1_024,
                maximumStandardInputBytes: HostwrightSupportBundleContract.maximumPlaintextBytes
            ))
        } catch {
            throw HostwrightSupportBundleError.encryptionFailed
        }
        guard result.exitStatus == 0,
              result.terminationSignal == nil,
              !result.standardOutput.isEmpty,
              result.standardOutput.count <= HostwrightSupportBundleContract.maximumEncryptedBytes,
              !result.standardOutputTruncated,
              !result.standardErrorTruncated else {
            throw HostwrightSupportBundleError.encryptionUnavailable
        }
        return result.standardOutput
    }
}

private struct SupportBundleBuild {
    let preview: HostwrightSupportBundlePreview
    let bundleData: Data
}

private struct SupportBundleConfirmation: Codable {
    let content: HostwrightSupportBundleContent
    let sections: [HostwrightSupportBundleSectionSummary]
}

private struct AnyEncodable: Encodable {
    private let encodeValue: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeValue = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}
