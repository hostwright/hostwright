import Foundation
import HostwrightRuntime

struct RuntimeQualificationRecoveryDetails: Codable, Equatable, Sendable {
    let recovery: RuntimeQualificationRecoveryEvidence
}

struct RuntimeQualificationRecoveryReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let status: String
    let scenario: String
    let subjects: [RuntimeQualificationSubject]
    let fixtureImage: RuntimeQualificationFixtureImage
    let inventory: RuntimeQualificationInventoryEvidence
    let unmanagedInventoryUnchanged: Bool
    let summary: RuntimeQualificationSummary
    let commands: [RuntimeQualificationCommandEvidence]
    let cleanup: RuntimeQualificationCleanupEvidence
    let details: RuntimeQualificationRecoveryDetails

    static func passed(execution: RuntimeQualificationRecoveryExecution) throws -> Self {
        let evidence = execution.evidence
        guard let scenario = RuntimeQualificationRecoveryScenario(rawValue: evidence.scenario),
              (try? RuntimeQualificationRecoverySpecification(
                providerID: RuntimeProviderID(rawValue: evidence.providerID),
                expectedVersion: evidence.providerVersion,
                scenario: scenario,
                localImage: evidence.fixtureImageReference,
                priorHelperURL: scenario == .staleHelper
                    ? URL(fileURLWithPath: "/evidence/hostwright-containerization-helper")
                    : nil
              ).validated()) != nil,
              evidence.schemaVersion == 1,
              evidence.passedAssertions > 0,
              evidence.failedAssertions == 0,
              evidence.cleanupComplete,
              evidence.unmanagedInventoryUnchanged,
              evidence.inventoryBeforeSHA256 == evidence.inventoryAfterSHA256,
              evidence.unmanagedBeforeSHA256 == evidence.unmanagedAfterSHA256,
              evidence.cleanupIdentifiers == execution.cleanupIdentifiers,
              Set(evidence.cleanupIdentifiers).count == evidence.cleanupIdentifiers.count,
              execution.fixtureImage.reference == evidence.fixtureImageReference,
              execution.fixtureImage.descriptorDigest == evidence.fixtureImageDescriptorDigest,
              execution.fixtureImage.variantDigest == evidence.fixtureImageVariantDigest,
              execution.fixtureImage.architecture == evidence.fixtureImageArchitecture,
              execution.fixtureImage.operatingSystem == evidence.fixtureImageOperatingSystem,
              evidence.fixtureImageArchitecture == "arm64",
              evidence.fixtureImageOperatingSystem == "linux",
              Self.digest(evidence.fixtureImageDescriptorDigest),
              Self.digest(evidence.fixtureImageVariantDigest),
              Self.sha256(evidence.capabilityBeforeSHA256),
              Self.sha256(evidence.capabilityAfterSHA256),
              Self.sha256(evidence.inventoryBeforeSHA256),
              Self.sha256(evidence.inventoryAfterSHA256),
              Self.sha256(evidence.unmanagedBeforeSHA256),
              Self.sha256(evidence.unmanagedAfterSHA256),
              Self.validCapabilityInvalidation(evidence, scenario: scenario),
              Set(evidence.recoveryChangeKinds).count == evidence.recoveryChangeKinds.count,
              evidence.recoveryChangeKinds.allSatisfy({ value in
                RuntimeProviderRecoveryChangeKind.allCases.contains { $0.rawValue == value }
              }),
              Set(evidence.recoveryFindingReasons).count == evidence.recoveryFindingReasons.count,
              evidence.recoveryFindingReasons.allSatisfy({ value in
                RuntimeProviderRecoveryFindingReason(rawValue: value) != nil
              }),
              evidence.providerGeneration == 1,
              Self.validHelperTransitionFields(evidence, scenario: scenario),
              Self.validScenario(evidence, scenario: scenario),
              Self.validProcessCycleCommands(
                execution.commands,
                scenario: scenario,
                executable: evidence.terminatedExecutable
              ),
              execution.commands.contains(where: {
                $0.arguments == [
                    "hostwright-runtime-conformance", "recovery",
                    evidence.providerID, evidence.scenario,
                ] && $0.exitStatus == 0
              }) else {
            throw RuntimeQualificationRecoveryDriverError.invalidEvidence
        }
        return Self(
            schemaVersion: 1,
            kind: "runtimeProviderRecoveryEvidence",
            status: "passed",
            scenario: evidence.scenario,
            subjects: [RuntimeQualificationSubject(
                providerID: evidence.providerID,
                providerVersion: evidence.providerVersion
            )],
            fixtureImage: RuntimeQualificationFixtureImage(
                reference: execution.fixtureImage.reference,
                digest: execution.fixtureImage.descriptorDigest
            ),
            inventory: RuntimeQualificationInventoryEvidence(
                beforeSHA256: evidence.inventoryBeforeSHA256,
                afterSHA256: evidence.inventoryAfterSHA256,
                unmanagedBeforeSHA256: evidence.unmanagedBeforeSHA256,
                unmanagedAfterSHA256: evidence.unmanagedAfterSHA256
            ),
            unmanagedInventoryUnchanged: true,
            summary: RuntimeQualificationSummary(
                passed: evidence.passedAssertions,
                failed: evidence.failedAssertions
            ),
            commands: execution.commands,
            cleanup: RuntimeQualificationCleanupEvidence(
                complete: true,
                identifiers: execution.cleanupIdentifiers
            ),
            details: RuntimeQualificationRecoveryDetails(recovery: evidence)
        )
    }

    private static func validScenario(
        _ evidence: RuntimeQualificationRecoveryEvidence,
        scenario: RuntimeQualificationRecoveryScenario
    ) -> Bool {
        guard let disposition = RuntimeProviderRecoveryDisposition(
            rawValue: evidence.recoveryDisposition
        ) else { return false }
        let reasons = Set(evidence.recoveryFindingReasons)
        let metadataStable = evidence.providerMetadataRevisionBefore ==
            RuntimeProviderMetadataEvidence.currentRevision &&
            evidence.providerMetadataRevisionAfter ==
            RuntimeProviderMetadataEvidence.currentRevision
        let noProcessCycle = evidence.durableCheckpointBefore == nil &&
            evidence.durableCheckpointAfter == nil &&
            evidence.terminatedExecutable == nil &&
            !evidence.processTreeTerminated &&
            evidence.stateSchemaVersion == nil &&
            evidence.cleanupIdentifiers.isEmpty

        switch scenario {
        case .cliServiceRestart, .helperRestart:
            return evidence.recoveryFindingReasons.isEmpty &&
                [.resumeFromCheckpoint, .reobserveThenResumeFromCheckpoint]
                    .contains(disposition) &&
                evidence.contractInput == "live-provider-snapshot" &&
                metadataStable && noProcessCycle
        case .hostwrightTermination:
            return evidence.recoveryFindingReasons.isEmpty &&
                disposition == .resumeFromCheckpoint &&
                evidence.contractInput == "live-provider-snapshot" &&
                metadataStable &&
                validProcessCycle(
                    evidence,
                    before: "prepared",
                    after: "recovered-after-hostwright-termination"
                )
        case .checkpointCrash:
            return evidence.recoveryFindingReasons.isEmpty &&
                disposition == .resumeFromCheckpoint &&
                evidence.contractInput == "live-provider-snapshot" &&
                metadataStable &&
                validProcessCycle(
                    evidence,
                    before: "runtime-effect-recorded",
                    after: "recovered-after-checkpoint-crash"
                )
        case .mixedComponentVersions:
            return disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(RuntimeProviderRecoveryFindingReason.mixedComponents.rawValue) &&
                evidence.contractInput == "mixed-component-contract-injection-from-live-snapshot" &&
                metadataStable && noProcessCycle
        case .staleHelper:
            return disposition == .reobserveThenResumeFromCheckpoint &&
                evidence.recoveryFindingReasons.isEmpty &&
                evidence.capabilitySnapshotInvalidated &&
                evidence.contractInput == "signed-h1-to-h2-helper-transition" &&
                evidence.providerMetadataRevisionBefore ==
                    RuntimeProviderMetadataEvidence.legacyRevision &&
                evidence.providerMetadataRevisionAfter ==
                    RuntimeProviderMetadataEvidence.currentRevision &&
                noProcessCycle
        case .futureProtocolRefusal:
            return disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(
                    RuntimeProviderRecoveryFindingReason.unsupportedFutureProtocol.rawValue
                ) &&
                evidence.contractInput == "future-protocol-contract-injection-from-live-snapshot" &&
                metadataStable && noProcessCycle
        case .downgradeRefusal:
            return disposition == .refuseAndPreserveCheckpoint &&
                reasons.contains(
                    RuntimeProviderRecoveryFindingReason.metadataRevisionTooNew.rawValue
                ) &&
                evidence.providerMetadataRevisionBefore ==
                    RuntimeProviderMetadataEvidence.currentRevision + 1 &&
                evidence.providerMetadataRevisionAfter ==
                    RuntimeProviderMetadataEvidence.currentRevision + 1 &&
                evidence.contractInput == "future-metadata-revision-against-live-snapshot" &&
                noProcessCycle
        }
    }

    private static func validCapabilityInvalidation(
        _ evidence: RuntimeQualificationRecoveryEvidence,
        scenario: RuntimeQualificationRecoveryScenario
    ) -> Bool {
        let digestChanged = evidence.capabilityBeforeSHA256 != evidence.capabilityAfterSHA256
        if scenario == .downgradeRefusal {
            return evidence.capabilitySnapshotInvalidated && !digestChanged
        }
        return evidence.capabilitySnapshotInvalidated == digestChanged
    }

    private static func validHelperTransitionFields(
        _ evidence: RuntimeQualificationRecoveryEvidence,
        scenario: RuntimeQualificationRecoveryScenario
    ) -> Bool {
        if scenario != .staleHelper {
            return evidence.priorHelperSHA256 == nil &&
                evidence.currentHelperSHA256 == nil &&
                !evidence.signedHelperTransitionVerified &&
                evidence.rollbackDisposition == nil &&
                evidence.rollbackFindingReasons.isEmpty
        }
        guard let prior = evidence.priorHelperSHA256,
              let current = evidence.currentHelperSHA256,
              sha256(prior), sha256(current), prior != current,
              evidence.signedHelperTransitionVerified,
              evidence.rollbackDisposition ==
                RuntimeProviderRecoveryDisposition.refuseAndPreserveCheckpoint.rawValue,
              evidence.rollbackFindingReasons == [
                RuntimeProviderRecoveryFindingReason.metadataRevisionTooNew.rawValue
              ] else {
            return false
        }
        return true
    }

    private static func validProcessCycle(
        _ evidence: RuntimeQualificationRecoveryEvidence,
        before: String,
        after: String
    ) -> Bool {
        evidence.durableCheckpointBefore == before &&
            evidence.durableCheckpointAfter == after &&
            evidence.terminatedExecutable == "hostwright-runtime-conformance" &&
            evidence.processTreeTerminated &&
            evidence.stateSchemaVersion == 7 &&
            !evidence.cleanupIdentifiers.isEmpty
    }

    private static func validProcessCycleCommands(
        _ commands: [RuntimeQualificationCommandEvidence],
        scenario: RuntimeQualificationRecoveryScenario,
        executable: String?
    ) -> Bool {
        if scenario == .staleHelper {
            let required: [(arguments: [String], status: Int)] = [
                (["hostwright-containerization-helper", "negotiate", "h1"], 0),
                (["hostwright-containerization-helper", "shutdown", "h1"], 0),
                (["hostwright-containerization-helper", "negotiate", "h2"], 0),
                (["hostwright-containerization-helper", "shutdown", "h2"], 0),
            ]
            return required.allSatisfy { requiredCommand in
                commands.contains {
                    $0.arguments == requiredCommand.arguments &&
                        $0.exitStatus == requiredCommand.status
                }
            }
        }
        guard scenario == .hostwrightTermination || scenario == .checkpointCrash else {
            return true
        }
        guard let executable, executable == "hostwright-runtime-conformance" else {
            return false
        }
        return commands.contains {
            $0.arguments == [executable, "recovery-worker-write"] &&
                $0.exitStatus == -1
        } && commands.contains {
            $0.arguments == [executable, "recovery-worker-resume"] &&
                $0.exitStatus == 0
        }
    }

    private static func sha256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func digest(_ value: String) -> Bool {
        value.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}
