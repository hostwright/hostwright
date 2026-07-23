import XCTest
@testable import HostwrightRuntime

final class Gate03RecoveryEvidenceTests: XCTestCase {
    func testActorSpecificRestartsHaveDeterministicCheckpointRecovery() {
        let cli = gate03RecoveryCLISnapshot(
            cliFingerprint: gate03RecoveryDigest("1"),
            serviceFingerprint: gate03RecoveryDigest("1")
        )
        let hostwrightRestart = evaluate(
            record: recoveryRecord(snapshot: cli),
            current: cli
        )
        XCTAssertEqual(hostwrightRestart.disposition, .resumeFromCheckpoint)
        XCTAssertFalse(hostwrightRestart.invalidatesCapabilitySnapshot)
        XCTAssertEqual(hostwrightRestart.changes, [])
        XCTAssertEqual(hostwrightRestart.providerGeneration, 7)

        let apiServiceRestart = evaluate(
            record: recoveryRecord(snapshot: cli),
            current: cli
        )
        XCTAssertEqual(apiServiceRestart.disposition, .resumeFromCheckpoint)
        XCTAssertFalse(apiServiceRestart.invalidatesCapabilitySnapshot)
        XCTAssertEqual(apiServiceRestart.providerGeneration, 7)
        XCTAssertEqual(apiServiceRestart.changes, [])

        let mixedAPIServiceReplacement = evaluate(
            record: recoveryRecord(snapshot: cli),
            current: gate03RecoveryCLISnapshot(
                cliFingerprint: gate03RecoveryDigest("1"),
                serviceFingerprint: gate03RecoveryDigest("2")
            )
        )
        XCTAssertEqual(mixedAPIServiceReplacement.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertTrue(mixedAPIServiceReplacement.invalidatesCapabilitySnapshot)
        XCTAssertTrue(mixedAPIServiceReplacement.findings.contains {
            $0.reason == .mixedComponents && $0.component == .appleContainerAPIService
        })
        XCTAssertTrue(mixedAPIServiceReplacement.changes.contains {
            $0.kind == .componentFingerprint &&
                $0.component == .appleContainerAPIService
        })

        let helper = gate03RecoveryHelperSnapshot(
            helperVersion: "0.0.2-h1",
            helperFingerprint: gate03RecoveryDigest("3")
        )
        let helperRestart = evaluate(
            record: recoveryRecord(snapshot: helper),
            current: helper
        )
        XCTAssertEqual(helperRestart.disposition, .resumeFromCheckpoint)
        XCTAssertFalse(helperRestart.invalidatesCapabilitySnapshot)
        XCTAssertEqual(helperRestart.providerGeneration, 7)
        XCTAssertEqual(helperRestart.changes, [])

        let replacedHelper = evaluate(
            record: recoveryRecord(snapshot: helper),
            current: gate03RecoveryHelperSnapshot(
                helperVersion: "0.0.2-h1",
                helperFingerprint: gate03RecoveryDigest("4")
            )
        )
        XCTAssertEqual(replacedHelper.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertTrue(replacedHelper.invalidatesCapabilitySnapshot)
        XCTAssertEqual(replacedHelper.providerGeneration, 7)
        XCTAssertEqual(replacedHelper.nextProviderMetadataRevision, 1)
        XCTAssertTrue(replacedHelper.changes.contains {
            $0.kind == .componentFingerprint &&
                $0.component == .appleContainerizationHelper
        })
    }

    func testStaleH1HelperRefusesAfterH2MetadataAdvance() {
        let h1 = gate03RecoveryHelperSnapshot(
            helperVersion: "0.0.2-h1",
            helperFingerprint: gate03RecoveryDigest("1")
        )
        let h2 = gate03RecoveryHelperSnapshot(
            helperVersion: "0.0.2-h2",
            helperFingerprint: gate03RecoveryDigest("2")
        )
        let result = RuntimeProviderRecoveryEvaluator.evaluate(
            record: recoveryRecord(snapshot: h2, metadataRevision: 2),
            currentSnapshot: h1,
            metadataSupport: RuntimeProviderMetadataSupport(
                minimumReadableRevision: 1,
                currentWritableRevision: 1
            )
        )

        XCTAssertEqual(result.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertTrue(result.invalidatesCapabilitySnapshot)
        XCTAssertEqual(result.providerGeneration, 7)
        XCTAssertEqual(result.nextProviderMetadataRevision, 2)
        XCTAssertEqual(result.findings.map(\.reason), [.metadataRevisionTooNew])
        XCTAssertTrue(result.changes.contains {
            $0.kind == .componentVersion &&
                $0.component == .appleContainerizationHelper &&
                $0.previousValue == "0.0.2-h2" &&
                $0.currentValue == "0.0.2-h1"
        })
    }

    func testH1RecoveryAdvancesOnlyAfterMatchingFreshH2Observation() throws {
        let h1 = gate03RecoveryHelperSnapshot(
            helperVersion: "0.0.2-h1",
            helperFingerprint: gate03RecoveryDigest("1")
        )
        let h2 = gate03RecoveryHelperSnapshot(
            helperVersion: "0.0.2-h2",
            helperFingerprint: gate03RecoveryDigest("2")
        )
        let record = recoveryRecord(snapshot: h1, metadataRevision: 1)
        let support = RuntimeProviderMetadataSupport(
            minimumReadableRevision: 1,
            currentWritableRevision: 2
        )

        let beforeFreshObservation = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: h2,
            metadataSupport: support
        )
        XCTAssertEqual(beforeFreshObservation.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertEqual(beforeFreshObservation.nextProviderMetadataRevision, 1)

        let wrongObservation = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: h2,
            metadataSupport: support,
            freshPersistedEvidence: try gate03RecoveryEvidence(for: h1)
        )
        XCTAssertEqual(wrongObservation.nextProviderMetadataRevision, 1)

        let afterFreshObservation = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: h2,
            metadataSupport: support,
            freshPersistedEvidence: try gate03RecoveryEvidence(for: h2)
        )
        XCTAssertEqual(afterFreshObservation.nextProviderMetadataRevision, 2)
        XCTAssertEqual(afterFreshObservation.providerGeneration, 7)
    }

    func testLegacyAdapterBindingMapsToStableProviderWithoutChangingGeneration() {
        let snapshot = gate03RecoveryCLISnapshot(
            cliFingerprint: gate03RecoveryDigest("1"),
            serviceFingerprint: gate03RecoveryDigest("1")
        )
        let result = evaluate(
            record: recoveryRecord(
                snapshot: snapshot,
                binding: "AppleContainerApplyAdapter"
            ),
            current: snapshot
        )

        XCTAssertEqual(
            result.bindingDecision,
            .migrateLegacy(from: "AppleContainerApplyAdapter", to: .appleContainerCLI)
        )
        XCTAssertEqual(result.providerGeneration, 7)
        XCTAssertEqual(result.disposition, .resumeFromCheckpoint)
        XCTAssertFalse(result.invalidatesCapabilitySnapshot)
    }

    private func evaluate(
        record: RuntimeProviderRecoveryRecord,
        current: RuntimeCapabilitySnapshot
    ) -> RuntimeProviderRecoveryEvaluation {
        RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: current,
            metadataSupport: RuntimeProviderMetadataSupport(
                minimumReadableRevision: 1,
                currentWritableRevision: 2
            )
        )
    }

    private func recoveryRecord(
        snapshot: RuntimeCapabilitySnapshot,
        binding: String? = nil,
        metadataRevision: Int = 1
    ) -> RuntimeProviderRecoveryRecord {
        RuntimeProviderRecoveryRecord(
            persistedProviderBinding: binding ?? snapshot.descriptor.providerID.rawValue,
            providerGeneration: 7,
            providerMetadataRevision: metadataRevision,
            fingerprint: RuntimeProviderRecoveryFingerprint(snapshot: snapshot)
        )
    }
}

private func gate03RecoveryCLISnapshot(
    cliFingerprint: String,
    serviceFingerprint: String
) -> RuntimeCapabilitySnapshot {
    gate03RecoverySnapshot(
        providerID: .appleContainerCLI,
        components: [
            RuntimeProviderComponent(
                identifier: .appleContainerCLI,
                version: "1.1.0",
                build: "release",
                fingerprint: cliFingerprint
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerAPIService,
                version: "1.1.0",
                build: "release",
                fingerprint: serviceFingerprint
            )
        ]
    )
}

private func gate03RecoveryHelperSnapshot(
    helperVersion: String,
    helperFingerprint: String
) -> RuntimeCapabilitySnapshot {
    gate03RecoverySnapshot(
        providerID: .appleContainerization,
        components: [
            RuntimeProviderComponent(
                identifier: .appleContainerizationHelper,
                version: helperVersion,
                build: "test",
                fingerprint: helperFingerprint
            ),
            RuntimeProviderComponent(
                identifier: .containerizationHelperProtocolV1,
                version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                build: "test",
                fingerprint: gate03RecoveryDigest("a")
            ),
            RuntimeProviderComponent(
                identifier: .appleContainerizationFramework,
                version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                build: "release",
                fingerprint: gate03RecoveryDigest("b")
            )
        ]
    )
}

private func gate03RecoverySnapshot(
    providerID: RuntimeProviderID,
    components: [RuntimeProviderComponent]
) -> RuntimeCapabilitySnapshot {
    RuntimeCapabilitySnapshot(
        descriptor: RuntimeProviderDescriptor(
            providerID: providerID,
            components: components,
            minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
            supportedArchitectures: [.arm64]
        ),
        host: RuntimeProviderHostPlatform(
            macOSVersion: RuntimeProviderMacOSVersion(major: 26),
            macOSBuild: "25A123",
            architecture: .arm64
        ),
        features: RuntimeProviderFeature.knownValues.map {
            RuntimeProviderFeatureStatus(
                feature: $0,
                state: .available,
                reason: .implemented
            )
        }
    )
}

private func gate03RecoveryEvidence(
    for snapshot: RuntimeCapabilitySnapshot
) throws -> RuntimeProviderMetadataEvidence {
    try RuntimeProviderMetadataEvidence.parse(
        entries: RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
            to: [RuntimeCapability.readOnlyObservation.rawValue],
            capabilitySHA256: snapshot.canonicalSHA256
        )
    )
}

private func gate03RecoveryDigest(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}
