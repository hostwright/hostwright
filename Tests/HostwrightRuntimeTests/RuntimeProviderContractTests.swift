import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class RuntimeProviderContractTests: XCTestCase {
    func testRuntimeMetadataAdvertisesProviderAPIV2() {
        let metadata = RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "test-provider",
            adapterVersion: "1.0.0",
            runtimeName: "test-runtime",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )

        XCTAssertEqual(metadata.providerAPIVersion, HostwrightContractVersions.runtimeProviderAPI)
        XCTAssertEqual(
            RuntimeProviderCompatibility.mutationIncompatibility(metadata),
            "Runtime provider test-provider does not authorize lifecycle mutation."
        )
    }

    func testMutationCompatibilityRejectsOtherProviderAPIVersions() {
        let metadata = RuntimeAdapterMetadata(
            providerAPIVersion: 1,
            providerID: .appleContainerCLI,
            adapterName: "legacy-provider",
            adapterVersion: "1.0.0",
            runtimeName: "legacy-runtime",
            supportsMutation: true,
            capabilities: [.lifecycleMutation]
        )

        XCTAssertEqual(
            RuntimeProviderCompatibility.mutationIncompatibility(metadata),
            "Runtime provider legacy-provider advertises API v1; Hostwright requires Runtime Provider API v2."
        )
    }

    func testMutationCompatibilityRejectsMissingMutationAuthorizationAndCapability() {
        let unauthorized = RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "read-only-provider",
            adapterVersion: "1.0.0",
            runtimeName: "read-only-runtime",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
        XCTAssertEqual(
            RuntimeProviderCompatibility.mutationIncompatibility(unauthorized),
            "Runtime provider read-only-provider does not authorize lifecycle mutation."
        )

        let missingCapability = RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "incomplete-provider",
            adapterVersion: "1.0.0",
            runtimeName: "incomplete-runtime",
            supportsMutation: true,
            capabilities: [.readOnlyObservation]
        )
        XCTAssertEqual(
            RuntimeProviderCompatibility.mutationIncompatibility(missingCapability),
            "Runtime provider incomplete-provider does not advertise the lifecycleMutation capability required for Hostwright mutation."
        )
    }

    func testCheckedInRuntimeProviderMetadataGoldenDecodesThroughProductionContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2/runtime-provider-metadata.json")
        let metadata = try JSONDecoder().decode(
            RuntimeAdapterMetadata.self,
            from: Data(contentsOf: root)
        )

        XCTAssertEqual(metadata.providerAPIVersion, HostwrightContractVersions.runtimeProviderAPI)
        XCTAssertEqual(metadata.providerID, .appleContainerCLI)
        XCTAssertEqual(metadata.adapterName, "golden-provider")
        XCTAssertEqual(metadata.capabilities, [.readOnlyObservation, .lifecycleMutation])
        XCTAssertNil(RuntimeProviderCompatibility.mutationIncompatibility(metadata))
    }

    func testMutationContextRequiresProviderDigestUUIDAndGenerationBindings() {
        let valid = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: digest("a"),
            operationID: "operation-1",
            resourceUUID: HostwrightResourceUUID.generate(),
            resourceGeneration: 1,
            projectResourceUUID: HostwrightResourceUUID.generate(),
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: HostwrightResourceUUID.generate()
        )
        XCTAssertNil(valid.validationIssue)

        let invalid = RuntimeMutationContext(
            providerAPIVersion: 1,
            providerID: RuntimeProviderID(rawValue: "invalid-provider"),
            capabilitySHA256: "invalid-digest",
            operationID: "",
            resourceUUID: "runtime-name",
            resourceGeneration: 0,
            projectResourceUUID: "project-name",
            projectGeneration: 0,
            providerGeneration: 0,
            fencingToken: "stale"
        )
        XCTAssertNotNil(invalid.validationIssue)
    }

    func testCapabilityContractUsesStableProviderComponentFeatureStateAndReasonIdentifiers() {
        XCTAssertEqual(RuntimeProviderID.appleContainerCLI.rawValue, "apple-container-cli")
        XCTAssertEqual(RuntimeProviderID.appleContainerization.rawValue, "apple-containerization")
        XCTAssertEqual(
            RuntimeProviderComponentID.knownValues.map(\.rawValue),
            [
                "container",
                "container-apiserver",
                "hostwright-containerization-helper",
                "hostwright-containerization-helper-protocol",
                "apple-containerization-framework"
            ]
        )
        XCTAssertEqual(RuntimeProviderCapabilityContract.helperProtocolVersion, "1")
        XCTAssertEqual(RuntimeProviderCapabilityContract.containerizationFrameworkVersion, "0.35.0")
        XCTAssertEqual(
            RuntimeProviderCapabilityState.allCases.map(\.rawValue),
            ["available", "experimental", "unavailable", "degraded", "blocked"]
        )
        XCTAssertEqual(RuntimeProviderCompatibilityReason.componentMissing.rawValue, "component-missing")
        XCTAssertEqual(RuntimeProviderFeatureReason.qualificationIncomplete.rawValue, "qualification-incomplete")
    }

    func testCheckedInCapabilityGoldenIsExactCanonicalV2AndNegotiates() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v0.0.2/runtime-provider-capabilities.json")
        let checkedIn = try Data(contentsOf: url)
        let snapshot = try JSONDecoder().decode(
            RuntimeCapabilitySnapshot.self,
            from: checkedIn
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(snapshot)
        let checkedInWithoutTrailingNewline = checkedIn.last == 0x0a
            ? Data(checkedIn.dropLast())
            : checkedIn

        XCTAssertEqual(canonical, checkedInWithoutTrailingNewline)
        XCTAssertEqual(snapshot.schemaVersion, RuntimeCapabilitySnapshot.currentSchemaVersion)
        XCTAssertEqual(
            snapshot.descriptor.components.map(\.identifier),
            [.appleContainerCLI, .appleContainerAPIService]
        )
        XCTAssertEqual(snapshot.host.macOSBuild, "25A123")
        XCTAssertEqual(RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot), [])
        XCTAssertEqual(
            snapshot.canonicalSHA256,
            "2d26d3161314fead0bac3557c025c31af208514b23036b4c6ebee1c065a99f92"
        )

        let available = RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: .appleContainerCLI,
            requiredFeatures: [.cancellation, .timeouts]
        )
        XCTAssertEqual(available.state, .available)
        XCTAssertEqual(available.findings, [])

        let experimental = RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: .appleContainerCLI,
            requiredFeatures: [.observation]
        )
        XCTAssertEqual(experimental.state, .experimental)
        XCTAssertEqual(
            experimental.findings,
            [RuntimeProviderCompatibilityFinding(reason: .featureExperimental, feature: .observation)]
        )
    }

    func testCapabilitySnapshotAndDigestAreCanonicalAndCaptureTimeFree() throws {
        let first = makeSnapshot(
            components: Array(cliComponents().reversed()),
            supportedArchitectures: [.arm64],
            features: Array(completeFeatureStatuses().reversed())
        )
        let second = makeSnapshot()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.canonicalSHA256, second.canonicalSHA256)
        XCTAssertEqual(first.canonicalSHA256.count, 64)
        XCTAssertNotNil(first.canonicalSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression))

        var changedComponents = cliComponents()
        changedComponents[0] = component(
            .appleContainerCLI,
            version: "1.1.0",
            build: "debug",
            fingerprint: "5973b9c"
        )
        XCTAssertNotEqual(
            first.canonicalSHA256,
            makeSnapshot(components: changedComponents).canonicalSHA256
        )
        XCTAssertNotEqual(
            first.canonicalSHA256,
            makeSnapshot(hostBuild: "25A124").canonicalSHA256
        )
        XCTAssertNotEqual(
            first.canonicalSHA256,
            makeSnapshot(components: cliComponents(fingerprint: "abcdef0")).canonicalSHA256
        )

        let encoded = try JSONEncoder().encode(first)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("capturedAt"))
    }

    func testComponentSetsFailClosedOnDuplicateMissingMixedAndUnknownEvidence() {
        let duplicate = makeSnapshot(components: cliComponents() + [cliComponents()[0]])
        XCTAssertTrue(
            findings(duplicate).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentDuplicate,
                    component: .appleContainerCLI
                )
            )
        )

        let missing = makeSnapshot(
            components: cliComponents().filter { $0.identifier != .appleContainerAPIService }
        )
        XCTAssertEqual(
            findings(missing),
            [
                RuntimeProviderCompatibilityFinding(
                    reason: .componentMissing,
                    component: .appleContainerAPIService
                )
            ]
        )

        let mixed = makeSnapshot(
            components: cliComponents() + [helperComponents()[1]]
        )
        XCTAssertTrue(
            findings(mixed).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentMixed,
                    component: .appleContainerizationHelper
                )
            )
        )

        let unknownID = RuntimeProviderComponentID(rawValue: "future-component")
        let unknown = makeSnapshot(
            components: cliComponents() + [
                component(unknownID, version: "1.0.0", build: "release", fingerprint: "abcdef0")
            ]
        )
        XCTAssertTrue(
            findings(unknown).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentUnknown,
                    component: unknownID
                )
            )
        )
    }

    func testComponentIdentityRejectsMixedAndUnsupportedVersionsAndMalformedEvidence() {
        let mixed = makeSnapshot(
            components: [
                component(.appleContainerCLI),
                component(.appleContainerAPIService, version: "1.0.0", fingerprint: "ee848e3")
            ]
        )
        XCTAssertTrue(
            findings(mixed).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentMixed,
                    component: .appleContainerAPIService
                )
            )
        )

        var unsupportedFramework = helperComponents()
        unsupportedFramework[0] = component(
            .appleContainerizationFramework,
            version: "0.34.0",
            build: "release",
            fingerprint: digest("c")
        )
        XCTAssertTrue(
            findings(
                makeSnapshot(
                    providerID: .appleContainerization,
                    components: unsupportedFramework
                )
            ).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentVersionUnsupported,
                    component: .appleContainerizationFramework
                )
            )
        )

        var unsupportedProtocol = helperComponents()
        unsupportedProtocol[2] = component(
            .containerizationHelperProtocolV1,
            version: "2",
            build: "canonical-json",
            fingerprint: digest("b")
        )
        XCTAssertTrue(
            findings(
                makeSnapshot(
                    providerID: .appleContainerization,
                    components: unsupportedProtocol
                )
            ).contains(
                RuntimeProviderCompatibilityFinding(
                    reason: .componentVersionUnsupported,
                    component: .containerizationHelperProtocolV1
                )
            )
        )

        let malformed = makeSnapshot(
            components: [
                component(.appleContainerCLI, build: "release build", fingerprint: "short"),
                component(.appleContainerAPIService)
            ]
        )
        XCTAssertEqual(
            Set(findings(malformed).map(\.reason)),
            [.componentBuildInvalid, .componentFingerprintInvalid, .componentMixed]
        )
    }

    func testCapabilityValidationCoversProviderMacOSBuildAndArchitectureBoundaries() {
        XCTAssertEqual(
            reasonSet(makeSnapshot(providerAPIVersion: 1)),
            [.providerAPIUnsupported]
        )
        XCTAssertTrue(
            reasonSet(
                makeSnapshot(providerID: RuntimeProviderID(rawValue: "future-provider"))
            ).contains(.providerUnknown)
        )
        XCTAssertEqual(
            reasonSet(
                makeSnapshot(
                    minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26, minor: 1),
                    hostMacOSVersion: RuntimeProviderMacOSVersion(major: 26)
                )
            ),
            [.macOSUnsupported]
        )
        XCTAssertEqual(
            reasonSet(makeSnapshot(hostBuild: "invalid build")),
            [.macOSBuildInvalid]
        )
        XCTAssertEqual(
            reasonSet(
                makeSnapshot(
                    hostArchitecture: RuntimeProviderArchitecture(rawValue: "x86_64")
                )
            ),
            [.architectureUnknown]
        )
        XCTAssertEqual(
            reasonSet(makeSnapshot(supportedArchitectures: [])),
            [.architectureUnknown, .architectureUnsupported]
        )
        XCTAssertEqual(
            reasonSet(makeSnapshot(supportedArchitectures: [.arm64, .arm64])),
            [.architectureDuplicate]
        )
    }

    func testUnknownMissingDuplicateAndInvalidFeatureDeclarationsFailClosed() {
        let unknown = RuntimeProviderFeature(rawValue: "future-feature")
        let unknownSnapshot = makeSnapshot(
            features: completeFeatureStatuses() + [
                RuntimeProviderFeatureStatus(
                    feature: unknown,
                    state: .unavailable,
                    reason: .notImplemented
                )
            ]
        )
        XCTAssertEqual(
            findings(unknownSnapshot),
            [RuntimeProviderCompatibilityFinding(reason: .featureUnknown, feature: unknown)]
        )

        let missing = makeSnapshot(
            features: completeFeatureStatuses().filter { $0.feature != .storage }
        )
        XCTAssertEqual(
            findings(missing),
            [RuntimeProviderCompatibilityFinding(reason: .featureMissing, feature: .storage)]
        )

        let duplicate = makeSnapshot(
            features: completeFeatureStatuses() + [
                RuntimeProviderFeatureStatus(
                    feature: .observation,
                    state: .available,
                    reason: .implemented
                )
            ]
        )
        XCTAssertEqual(
            findings(duplicate),
            [RuntimeProviderCompatibilityFinding(reason: .featureDuplicate, feature: .observation)]
        )

        var invalidReason = completeFeatureStatuses()
        invalidReason[0] = RuntimeProviderFeatureStatus(
            feature: invalidReason[0].feature,
            state: .available,
            reason: .notImplemented
        )
        XCTAssertEqual(
            findings(makeSnapshot(features: invalidReason)),
            [
                RuntimeProviderCompatibilityFinding(
                    reason: .featureReasonInvalid,
                    feature: invalidReason[0].feature
                )
            ]
        )
    }

    func testMixedFeatureStatesAggregateDeterministically() {
        let snapshot = makeSnapshot(
            features: completeFeatureStatuses(overrides: [
                .lifecycle: (.experimental, .qualificationIncomplete),
                .networks: (.degraded, .componentUnavailable),
                .storage: (.unavailable, .notImplemented),
                .streaming: (.blocked, .platformUnsupported)
            ])
        )

        XCTAssertEqual(
            negotiate(snapshot, required: [.observation, .lifecycle]).state,
            .experimental
        )
        XCTAssertEqual(
            negotiate(snapshot, required: [.lifecycle, .networks]).state,
            .degraded
        )
        XCTAssertEqual(
            negotiate(snapshot, required: [.networks, .storage]).state,
            .unavailable
        )
        XCTAssertEqual(
            negotiate(snapshot, required: [.storage, .streaming, .lifecycle]).state,
            .blocked
        )
    }

    func testContainerizationProviderRequiresHelperProtocolV1AndFramework0350() {
        let snapshot = makeSnapshot(
            providerID: .appleContainerization,
            components: helperComponents()
        )

        XCTAssertEqual(findings(snapshot), [])
        XCTAssertEqual(
            RuntimeProviderCapabilityNegotiator.negotiate(
                snapshot,
                expectedProviderID: .appleContainerCLI,
                requiredFeatures: [.observation]
            ).findings,
            [RuntimeProviderCompatibilityFinding(reason: .providerMismatch)]
        )
    }

    private func makeSnapshot(
        schemaVersion: Int = RuntimeCapabilitySnapshot.currentSchemaVersion,
        providerAPIVersion: Int = HostwrightContractVersions.runtimeProviderAPI,
        providerID: RuntimeProviderID = .appleContainerCLI,
        components: [RuntimeProviderComponent]? = nil,
        minimumMacOSVersion: RuntimeProviderMacOSVersion = RuntimeProviderCapabilityContract.minimumMacOSVersion,
        hostMacOSVersion: RuntimeProviderMacOSVersion = RuntimeProviderMacOSVersion(major: 26, minor: 1),
        hostBuild: String = "25A123",
        supportedArchitectures: [RuntimeProviderArchitecture] = [.arm64],
        hostArchitecture: RuntimeProviderArchitecture = .arm64,
        features: [RuntimeProviderFeatureStatus]? = nil
    ) -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            schemaVersion: schemaVersion,
            descriptor: RuntimeProviderDescriptor(
                providerAPIVersion: providerAPIVersion,
                providerID: providerID,
                components: components ?? cliComponents(),
                minimumMacOSVersion: minimumMacOSVersion,
                supportedArchitectures: supportedArchitectures
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: hostMacOSVersion,
                macOSBuild: hostBuild,
                architecture: hostArchitecture
            ),
            features: features ?? completeFeatureStatuses()
        )
    }

    private func cliComponents(
        version: String = "1.1.0",
        build: String = "release",
        fingerprint: String = "5973b9c"
    ) -> [RuntimeProviderComponent] {
        [
            component(
                .appleContainerCLI,
                version: version,
                build: build,
                fingerprint: fingerprint
            ),
            component(
                .appleContainerAPIService,
                version: version,
                build: build,
                fingerprint: fingerprint
            )
        ]
    }

    private func helperComponents() -> [RuntimeProviderComponent] {
        [
            component(
                .appleContainerizationFramework,
                version: "0.35.0",
                build: "release",
                fingerprint: digest("c")
            ),
            component(
                .appleContainerizationHelper,
                version: "0.0.2",
                build: "release",
                fingerprint: digest("a")
            ),
            component(
                .containerizationHelperProtocolV1,
                version: "1",
                build: "canonical-json",
                fingerprint: digest("b")
            )
        ]
    }

    private func component(
        _ identifier: RuntimeProviderComponentID,
        version: String = "1.1.0",
        build: String = "release",
        fingerprint: String = "5973b9c"
    ) -> RuntimeProviderComponent {
        RuntimeProviderComponent(
            identifier: identifier,
            version: version,
            build: build,
            fingerprint: fingerprint
        )
    }

    private func completeFeatureStatuses(
        overrides: [RuntimeProviderFeature: (RuntimeProviderCapabilityState, RuntimeProviderFeatureReason)] = [:]
    ) -> [RuntimeProviderFeatureStatus] {
        RuntimeProviderFeature.knownValues.map { feature in
            let stateAndReason = overrides[feature] ?? (.available, .implemented)
            return RuntimeProviderFeatureStatus(
                feature: feature,
                state: stateAndReason.0,
                reason: stateAndReason.1
            )
        }
    }

    private func findings(
        _ snapshot: RuntimeCapabilitySnapshot
    ) -> [RuntimeProviderCompatibilityFinding] {
        RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot)
    }

    private func reasonSet(
        _ snapshot: RuntimeCapabilitySnapshot
    ) -> Set<RuntimeProviderCompatibilityReason> {
        Set(findings(snapshot).map(\.reason))
    }

    private func negotiate(
        _ snapshot: RuntimeCapabilitySnapshot,
        required: [RuntimeProviderFeature]
    ) -> RuntimeProviderCompatibilityReport {
        RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: snapshot.descriptor.providerID,
            requiredFeatures: required
        )
    }

    private func digest(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
