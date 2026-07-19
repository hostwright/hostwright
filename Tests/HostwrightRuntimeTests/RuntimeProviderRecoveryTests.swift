import XCTest
@testable import HostwrightRuntime

final class RuntimeProviderRecoveryTests: XCTestCase {
    func testUnchangedH1FingerprintPlainResumeDoesNotAdvanceMetadata() {
        let snapshot = cliSnapshot(version: "1.1.0")
        let result = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: snapshot, metadataRevision: 1),
            currentSnapshot: snapshot,
            metadataSupport: RuntimeProviderMetadataSupport(
                minimumReadableRevision: 1,
                currentWritableRevision: 2
            )
        )

        XCTAssertEqual(result.disposition, .resumeFromCheckpoint)
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.findings, [])
        XCTAssertFalse(result.invalidatesCapabilitySnapshot)
        XCTAssertEqual(result.providerGeneration, 4)
        XCTAssertEqual(result.nextProviderMetadataRevision, 1)
    }

    func testUnchangedH1FingerprintAdvancesOnlyWithMatchingFreshPersistedEvidence() throws {
        let snapshot = cliSnapshot(version: "1.1.0")
        let support = RuntimeProviderMetadataSupport(
            minimumReadableRevision: 1,
            currentWritableRevision: 2
        )
        let record = record(snapshot: snapshot, metadataRevision: 1)

        let staleEvidence = try persistedEvidence(for: cliSnapshot(version: "1.0.0"))
        let stale = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: snapshot,
            metadataSupport: support,
            freshPersistedEvidence: staleEvidence
        )
        XCTAssertEqual(stale.nextProviderMetadataRevision, 1)

        let persisted = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: snapshot,
            metadataSupport: support,
            freshPersistedEvidence: try persistedEvidence(for: snapshot)
        )
        XCTAssertEqual(persisted.disposition, .resumeFromCheckpoint)
        XCTAssertEqual(persisted.nextProviderMetadataRevision, 2)
    }

    func testCLI10To11InvalidatesCapabilitiesAndReobservesBeforeResume() {
        let previous = cliSnapshot(version: "1.0.0", build: "100", fingerprint: digest("1"))
        let current = cliSnapshot(version: "1.1.0", build: "110", fingerprint: digest("2"))
        let result = evaluate(record(snapshot: previous), current: current)

        XCTAssertEqual(result.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertTrue(result.invalidatesCapabilitySnapshot)
        XCTAssertEqual(result.findings, [])
        XCTAssertTrue(result.changes.contains {
            $0.kind == .componentVersion && $0.component == .appleContainerCLI &&
                $0.previousValue == "1.0.0" && $0.currentValue == "1.1.0"
        })
        XCTAssertTrue(result.changes.contains {
            $0.kind == .componentVersion && $0.component == .appleContainerAPIService
        })
        XCTAssertEqual(result.providerGeneration, 4)
    }

    func testFingerprintOnlyDriftInvalidatesCapabilitiesBeforeResume() {
        let previous = cliSnapshot(
            version: "1.1.0",
            build: "110",
            fingerprint: digest("1")
        )
        let current = cliSnapshot(
            version: "1.1.0",
            build: "110",
            fingerprint: digest("2")
        )
        let result = evaluate(record(snapshot: previous), current: current)

        XCTAssertEqual(result.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertTrue(result.invalidatesCapabilitySnapshot)
        XCTAssertEqual(result.findings, [])
        XCTAssertTrue(result.changes.contains {
            $0.kind == .componentFingerprint &&
                $0.component == .appleContainerCLI
        })
    }

    func testHelperH1ToH2UpgradeAdvancesMetadataOnlyAfterReobservationIsPersisted() throws {
        let h1 = helperSnapshot(helperVersion: "0.0.2-dev.1", helperFingerprint: digest("1"))
        let h2 = helperSnapshot(helperVersion: "0.0.2-dev.2", helperFingerprint: digest("2"))
        let support = RuntimeProviderMetadataSupport(
            minimumReadableRevision: 1,
            currentWritableRevision: 2
        )
        let beforePersistence = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: h1, metadataRevision: 1),
            currentSnapshot: h2,
            metadataSupport: support
        )

        XCTAssertEqual(beforePersistence.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertEqual(beforePersistence.findings, [])
        XCTAssertEqual(beforePersistence.nextProviderMetadataRevision, 1)
        XCTAssertTrue(beforePersistence.changes.contains {
            $0.kind == .componentVersion &&
                $0.component == .appleContainerizationHelper &&
                $0.previousValue == "0.0.2-dev.1" &&
                $0.currentValue == "0.0.2-dev.2"
        })

        let afterPersistence = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: h1, metadataRevision: 1),
            currentSnapshot: h2,
            metadataSupport: support,
            freshPersistedEvidence: try persistedEvidence(for: h2)
        )
        XCTAssertEqual(afterPersistence.nextProviderMetadataRevision, 2)
    }

    func testStaleH1HelperRollbackIsAllowedOnlyBeforeIncompatibleMetadataAdvances() {
        let h1 = helperSnapshot(helperVersion: "0.0.2-dev.1", helperFingerprint: digest("1"))
        let h2 = helperSnapshot(helperVersion: "0.0.2-dev.2", helperFingerprint: digest("2"))
        let h1Support = RuntimeProviderMetadataSupport(
            minimumReadableRevision: 1,
            currentWritableRevision: 1
        )

        let beforeAdvance = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: h2, metadataRevision: 1),
            currentSnapshot: h1,
            metadataSupport: h1Support
        )
        XCTAssertEqual(beforeAdvance.disposition, .reobserveThenResumeFromCheckpoint)
        XCTAssertEqual(beforeAdvance.findings, [])

        let afterAdvance = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: h2, metadataRevision: 2),
            currentSnapshot: h1,
            metadataSupport: h1Support
        )
        XCTAssertEqual(afterAdvance.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertEqual(afterAdvance.nextProviderMetadataRevision, 2)
        XCTAssertEqual(afterAdvance.findings.map(\.reason), [.metadataRevisionTooNew])
    }

    func testMixedCLIAndAPIServiceVersionsRefuseRecovery() {
        let baseline = cliSnapshot(version: "1.0.0")
        let mixed = cliSnapshot(cliVersion: "1.1.0", serviceVersion: "1.0.0")
        let result = evaluate(record(snapshot: baseline), current: mixed)

        XCTAssertEqual(result.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertTrue(result.invalidatesCapabilitySnapshot)
        XCTAssertTrue(result.findings.contains {
            $0.reason == .mixedComponents && $0.component == .appleContainerAPIService
        })
    }

    func testFutureHelperProtocolRefusesWithoutAdvancingMetadata() {
        let baseline = helperSnapshot(helperVersion: "0.0.2-dev.2", helperFingerprint: digest("2"))
        let future = helperSnapshot(
            helperVersion: "0.0.2-dev.2",
            helperFingerprint: digest("2"),
            protocolVersion: "2"
        )
        let result = RuntimeProviderRecoveryEvaluator.evaluate(
            record: record(snapshot: baseline, metadataRevision: 1),
            currentSnapshot: future,
            metadataSupport: RuntimeProviderMetadataSupport(
                minimumReadableRevision: 1,
                currentWritableRevision: 2
            )
        )

        XCTAssertEqual(result.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertEqual(result.nextProviderMetadataRevision, 1)
        XCTAssertTrue(result.findings.contains {
            $0.reason == .unsupportedFutureProtocol &&
                $0.component == .containerizationHelperProtocolV1
        })
    }

    func testLegacyBindingsMigrateDeterministicallyWithoutChangingGeneration() {
        let cli = cliSnapshot(version: "1.1.0")
        let legacy = evaluate(
            record(
                snapshot: cli,
                binding: "AppleContainerApplyAdapter",
                providerGeneration: 7
            ),
            current: cli
        )
        XCTAssertEqual(
            legacy.bindingDecision,
            .migrateLegacy(from: "AppleContainerApplyAdapter", to: .appleContainerCLI)
        )
        XCTAssertEqual(legacy.providerGeneration, 7)
        XCTAssertEqual(legacy.disposition, .resumeFromCheckpoint)

        let unknown = evaluate(
            record(snapshot: cli, binding: "RemovedExperimentalAdapter"),
            current: cli
        )
        XCTAssertEqual(unknown.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertEqual(
            unknown.bindingDecision,
            .refuseUnknown("RemovedExperimentalAdapter")
        )
        XCTAssertEqual(unknown.findings.map(\.reason), [.unknownProviderBinding])
    }

    func testMacOSAndFrameworkChangesHaveStableSortedEvidence() {
        let previous = helperSnapshot(
            helperVersion: "0.0.2-dev.1",
            helperFingerprint: digest("1"),
            frameworkVersion: "0.34.0",
            macOSMinor: 0,
            macOSBuild: "25A100"
        )
        let current = helperSnapshot(
            helperVersion: "0.0.2-dev.2",
            helperFingerprint: digest("2"),
            macOSMinor: 1,
            macOSBuild: "25A200"
        )
        let first = RuntimeProviderRecoveryEvaluator.changes(
            from: RuntimeProviderRecoveryFingerprint(snapshot: previous),
            to: RuntimeProviderRecoveryFingerprint(snapshot: current)
        )
        let second = RuntimeProviderRecoveryEvaluator.changes(
            from: RuntimeProviderRecoveryFingerprint(snapshot: previous),
            to: RuntimeProviderRecoveryFingerprint(snapshot: current)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, first.sorted {
            ($0.kind.rawValue, $0.component?.rawValue ?? "") <
                ($1.kind.rawValue, $1.component?.rawValue ?? "")
        })
        XCTAssertTrue(first.contains { $0.kind == .macOSBuild })
        XCTAssertTrue(first.contains { $0.kind == .macOSVersion })
        XCTAssertTrue(first.contains {
            $0.kind == .componentVersion && $0.component == .appleContainerizationHelper
        })
        XCTAssertTrue(first.contains {
            $0.kind == .componentVersion && $0.component == .appleContainerizationFramework
        })
    }

    func testSchemaV7AndPositiveGenerationAreRequired() {
        let snapshot = cliSnapshot(version: "1.1.0")
        let invalid = RuntimeProviderRecoveryRecord(
            stateSchemaVersion: 8,
            persistedProviderBinding: RuntimeProviderID.appleContainerCLI.rawValue,
            providerGeneration: 0,
            providerMetadataRevision: 1,
            fingerprint: RuntimeProviderRecoveryFingerprint(snapshot: snapshot)
        )
        let result = evaluate(invalid, current: snapshot)

        XCTAssertEqual(result.disposition, .refuseAndPreserveCheckpoint)
        XCTAssertEqual(
            Set(result.findings.map(\.reason)),
            Set([.invalidProviderGeneration, .invalidStateSchema])
        )
    }

    private func evaluate(
        _ record: RuntimeProviderRecoveryRecord,
        current: RuntimeCapabilitySnapshot
    ) -> RuntimeProviderRecoveryEvaluation {
        RuntimeProviderRecoveryEvaluator.evaluate(
            record: record,
            currentSnapshot: current,
            metadataSupport: RuntimeProviderMetadataSupport(
                minimumReadableRevision: 1,
                currentWritableRevision: 1
            )
        )
    }

    private func record(
        snapshot: RuntimeCapabilitySnapshot,
        binding: String? = nil,
        providerGeneration: Int = 4,
        metadataRevision: Int = 1
    ) -> RuntimeProviderRecoveryRecord {
        RuntimeProviderRecoveryRecord(
            persistedProviderBinding: binding ?? snapshot.descriptor.providerID.rawValue,
            providerGeneration: providerGeneration,
            providerMetadataRevision: metadataRevision,
            fingerprint: RuntimeProviderRecoveryFingerprint(snapshot: snapshot)
        )
    }

    private func cliSnapshot(
        version: String = "1.1.0",
        build: String = "110",
        fingerprint: String? = nil,
        macOSBuild: String = "25A123"
    ) -> RuntimeCapabilitySnapshot {
        cliSnapshot(
            cliVersion: version,
            serviceVersion: version,
            build: build,
            fingerprint: fingerprint ?? digest("a"),
            macOSBuild: macOSBuild
        )
    }

    private func cliSnapshot(
        cliVersion: String,
        serviceVersion: String,
        build: String = "110",
        fingerprint: String? = nil,
        macOSBuild: String = "25A123"
    ) -> RuntimeCapabilitySnapshot {
        snapshot(
            providerID: .appleContainerCLI,
            components: [
                component(
                    .appleContainerCLI,
                    cliVersion,
                    build,
                    fingerprint ?? digest("a")
                ),
                component(
                    .appleContainerAPIService,
                    serviceVersion,
                    build,
                    fingerprint ?? digest("a")
                )
            ],
            macOSBuild: macOSBuild
        )
    }

    private func helperSnapshot(
        helperVersion: String,
        helperFingerprint: String,
        protocolVersion: String = "1",
        frameworkVersion: String = "0.35.0",
        macOSMinor: Int = 0,
        macOSBuild: String = "25A123"
    ) -> RuntimeCapabilitySnapshot {
        snapshot(
            providerID: .appleContainerization,
            components: [
                component(
                    .appleContainerizationHelper,
                    helperVersion,
                    "helper",
                    helperFingerprint
                ),
                component(
                    .containerizationHelperProtocolV1,
                    protocolVersion,
                    "protocol",
                    digest("b")
                ),
                component(
                    .appleContainerizationFramework,
                    frameworkVersion,
                    "framework",
                    digest("c")
                )
            ],
            macOSBuild: macOSBuild,
            macOSMinor: macOSMinor
        )
    }

    private func snapshot(
        providerID: RuntimeProviderID,
        components: [RuntimeProviderComponent],
        macOSBuild: String,
        macOSMinor: Int = 0
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: providerID,
                components: components,
                minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26, minor: macOSMinor),
                macOSBuild: macOSBuild,
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

    private func component(
        _ identifier: RuntimeProviderComponentID,
        _ version: String,
        _ build: String,
        _ fingerprint: String
    ) -> RuntimeProviderComponent {
        RuntimeProviderComponent(
            identifier: identifier,
            version: version,
            build: build,
            fingerprint: fingerprint
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func persistedEvidence(
        for snapshot: RuntimeCapabilitySnapshot
    ) throws -> RuntimeProviderMetadataEvidence {
        try RuntimeProviderMetadataEvidence.parse(
            entries: RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
                to: [RuntimeCapability.readOnlyObservation.rawValue],
                capabilitySHA256: snapshot.canonicalSHA256
            )
        )
    }
}
