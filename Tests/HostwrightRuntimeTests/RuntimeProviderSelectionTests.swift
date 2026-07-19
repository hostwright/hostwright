import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProviderSelectionTests: XCTestCase {
    func testAutoPrefersCLIAndFallsBackOnlyToFullyCapableHelper() throws {
        let result = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: nil,
            snapshots: [snapshot(providerID: .appleContainerization), snapshot(providerID: .appleContainerCLI)]
        )
        XCTAssertEqual(result.providerID, .appleContainerCLI)
        XCTAssertFalse(result.preservedBinding)

        let fallback = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: nil,
            snapshots: [
                snapshot(providerID: .appleContainerCLI, lifecycleState: .unavailable),
                snapshot(providerID: .appleContainerization)
            ]
        )
        XCTAssertEqual(fallback.providerID, .appleContainerization)
    }

    func testExistingBindingWinsAndExplicitSwitchRequiresMigration() throws {
        let snapshots = [snapshot(providerID: .appleContainerCLI), snapshot(providerID: .appleContainerization)]
        let selected = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: "AppleContainerApplyAdapter",
            snapshots: snapshots
        )
        XCTAssertEqual(selected.providerID, .appleContainerCLI)
        XCTAssertTrue(selected.preservedBinding)

        XCTAssertThrowsError(
            try RuntimeProviderSelector.select(
                requested: .containerization,
                existingBinding: RuntimeProviderID.appleContainerCLI.rawValue,
                snapshots: snapshots
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProviderSelectionError,
                .explicitProviderConflictsWithBinding(
                    bound: .appleContainerCLI,
                    requested: .appleContainerization
                )
            )
        }
    }

    func testStaleCapabilityIsRejectedDeterministically() {
        let current = snapshot(providerID: .appleContainerCLI)
        XCTAssertNoThrow(
            try RuntimeProviderSelector.requireFreshCapability(
                expectedSHA256: current.canonicalSHA256,
                currentSnapshot: current
            )
        )
        XCTAssertThrowsError(
            try RuntimeProviderSelector.requireFreshCapability(
                expectedSHA256: String(repeating: "0", count: 64),
                currentSnapshot: current
            )
        ) { error in
            guard case RuntimeProviderSelectionError.staleCapability = error else {
                return XCTFail("Expected stale capability, got \(error).")
            }
        }
    }

    func testUnknownLegacyBindingAndDuplicateSnapshotsFailClosed() {
        XCTAssertThrowsError(
            try RuntimeProviderSelector.select(
                requested: .automatic,
                existingBinding: "unknown-adapter",
                snapshots: [snapshot(providerID: .appleContainerCLI)]
            )
        )
        XCTAssertThrowsError(
            try RuntimeProviderSelector.select(
                requested: .automatic,
                existingBinding: nil,
                snapshots: [snapshot(providerID: .appleContainerCLI), snapshot(providerID: .appleContainerCLI)]
            )
        )
    }

    func testBoundProviderStableChangedAndLegacyEvidenceSetReobservationRequirement() throws {
        let current = snapshot(providerID: .appleContainerCLI)
        let stableEvidence = try RuntimeProviderMetadataEvidence.parse(
            entries: try RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
                to: [RuntimeCapability.readOnlyObservation.rawValue],
                capabilitySHA256: current.canonicalSHA256
            )
        )
        let stable = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: RuntimeProviderID.appleContainerCLI.rawValue,
            snapshots: [current],
            persistedEvidence: stableEvidence
        )
        XCTAssertFalse(stable.requiresReobservation)
        XCTAssertEqual(stable.reason, "Preserved the existing project provider binding.")

        let changedEvidence = try RuntimeProviderMetadataEvidence.parse(
            entries: try RuntimeProviderMetadataEvidence.appendingCurrentEvidence(
                to: [RuntimeCapability.readOnlyObservation.rawValue],
                capabilitySHA256: String(repeating: "0", count: 64)
            )
        )
        let changed = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: RuntimeProviderID.appleContainerCLI.rawValue,
            snapshots: [current],
            persistedEvidence: changedEvidence
        )
        XCTAssertTrue(changed.requiresReobservation)
        XCTAssertTrue(changed.reason.contains("fresh structured re-observation is required"))

        let legacyEvidence = try RuntimeProviderMetadataEvidence.parse(
            entries: [RuntimeCapability.readOnlyObservation.rawValue]
        )
        let legacy = try RuntimeProviderSelector.select(
            requested: .automatic,
            existingBinding: RuntimeProviderID.appleContainerCLI.rawValue,
            snapshots: [current],
            persistedEvidence: legacyEvidence
        )
        XCTAssertTrue(legacy.requiresReobservation)
        XCTAssertTrue(legacy.reason.contains("legacy provider metadata"))
    }

    func testBoundProviderRefusesPersistedMetadataFromNewerHostwright() throws {
        let current = snapshot(providerID: .appleContainerCLI)
        let newerEvidence = try RuntimeProviderMetadataEvidence.parse(
            entries: [
                RuntimeProviderMetadataEvidence.capabilitySHA256MarkerPrefix + current.canonicalSHA256,
                RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "2"
            ]
        )

        XCTAssertThrowsError(
            try RuntimeProviderSelector.select(
                requested: .automatic,
                existingBinding: RuntimeProviderID.appleContainerCLI.rawValue,
                snapshots: [],
                persistedEvidence: newerEvidence
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProviderSelectionError,
                .unsupportedProviderMetadataDowngrade(persistedRevision: 2, currentRevision: 1)
            )
        }
    }

    private func snapshot(
        providerID: RuntimeProviderID,
        lifecycleState: RuntimeProviderCapabilityState = .available
    ) -> RuntimeCapabilitySnapshot {
        let components: [RuntimeProviderComponent]
        if providerID == .appleContainerCLI {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerCLI,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: "5973b9c"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerAPIService,
                    version: "1.1.0",
                    build: "release",
                    fingerprint: "5973b9c"
                )
            ]
        } else {
            components = [
                RuntimeProviderComponent(
                    identifier: .appleContainerizationHelper,
                    version: "0.0.2",
                    build: "test",
                    fingerprint: "abcdef0"
                ),
                RuntimeProviderComponent(
                    identifier: .containerizationHelperProtocolV1,
                    version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                    build: "test",
                    fingerprint: "abcdef1"
                ),
                RuntimeProviderComponent(
                    identifier: .appleContainerizationFramework,
                    version: RuntimeProviderCapabilityContract.containerizationFrameworkVersion,
                    build: "release",
                    fingerprint: "abcdef2"
                )
            ]
        }
        let features = RuntimeProviderFeature.knownValues.map { feature in
            let state: RuntimeProviderCapabilityState = feature == .lifecycle ? lifecycleState : .available
            return RuntimeProviderFeatureStatus(
                feature: feature,
                state: state,
                reason: state == .available ? .implemented : .componentUnavailable
            )
        }
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: providerID,
                components: components,
                minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26),
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(major: 26),
                macOSBuild: "25A123",
                architecture: .arm64
            ),
            features: features
        )
    }
}
