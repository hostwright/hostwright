import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class RuntimeProviderRecoverySelectionCLITests: XCTestCase {
    private let projectID = "project-demo"
    private let currentSnapshot = ScriptedRuntimeAdapter.testCapabilitySnapshot

    func testStableLatestSameProviderEvidenceResumesAcrossMixedHistory() throws {
        try withStore { store, _ in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-old-changed",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: String(repeating: "0", count: 64),
                observedAt: "2026-07-19T12:00:00Z"
            )
            try saveSnapshot(
                store,
                id: "cli-latest-stable",
                providerID: .appleContainerCLI,
                runtimeAdapter: "AppleContainerReadOnlyAdapter",
                digest: currentSnapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:02:00Z"
            )
            try saveSnapshot(
                store,
                id: "helper-newest-overall",
                providerID: .appleContainerization,
                runtimeAdapter: RuntimeProviderID.appleContainerization.rawValue,
                digest: String(repeating: "f", count: 64),
                observedAt: "2026-07-19T12:03:00Z"
            )

            let selected = try select(store: store)
            XCTAssertEqual(selected.selection.providerID, .appleContainerCLI)
            XCTAssertFalse(selected.selection.requiresReobservation)
            XCTAssertEqual(
                selected.selection.reason,
                "Preserved the existing project provider binding."
            )
        }
    }

    func testLegacyEvidenceRequiresFreshStructuredReobservation() throws {
        try withStore { store, _ in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-legacy",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: nil,
                observedAt: "2026-07-19T12:00:00Z"
            )

            let selected = try select(store: store)
            XCTAssertTrue(selected.selection.requiresReobservation)
            XCTAssertTrue(selected.selection.reason.contains("legacy provider metadata"))
            XCTAssertTrue(selected.selection.reason.contains("fresh structured re-observation"))
        }
    }

    func testChangedDigestRequiresFreshStructuredReobservation() throws {
        try withStore { store, _ in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-changed",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: String(repeating: "0", count: 64),
                observedAt: "2026-07-19T12:00:00Z"
            )

            let selected = try select(store: store)
            XCTAssertTrue(selected.selection.requiresReobservation)
            XCTAssertTrue(selected.selection.reason.contains("capability digest changed"))
            XCTAssertTrue(selected.selection.reason.contains("fresh structured re-observation is required"))
        }
    }

    func testNewerPersistedRevisionRefusesDowngradeBeforeReturningAdapter() throws {
        try withStore { store, databaseURL in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-newer-revision",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: currentSnapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:00:00Z"
            )
            let record = try XCTUnwrap(
                try store.observedStates.loadLatestSnapshot(
                    projectID: projectID,
                    providerID: .appleContainerCLI
                )
            )
            let data = try XCTUnwrap(record.capabilitiesJSON.data(using: .utf8))
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
            entries[entries.count - 1] =
                RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "3"
            let updatedData = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            let updatedJSON = try XCTUnwrap(String(data: updatedData, encoding: .utf8))
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "UPDATE observed_runtime_snapshots SET capabilities_json = ? WHERE id = ?",
                bindings: [.text(updatedJSON), .text(record.id)]
            )

            XCTAssertThrowsError(try select(store: store)) { error in
                XCTAssertEqual(
                    error as? RuntimeProviderSelectionError,
                    .unsupportedProviderMetadataDowngrade(
                        persistedRevision: 3,
                        currentRevision: 2
                    )
                )
            }
        }
    }

    func testDuplicatePersistedReservedEvidenceIsRejectedWithoutExposingState() throws {
        try withStore { store, databaseURL in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-duplicate-evidence",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: currentSnapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:00:00Z"
            )
            let record = try XCTUnwrap(
                try store.observedStates.loadLatestSnapshot(
                    projectID: projectID,
                    providerID: .appleContainerCLI
                )
            )
            let data = try XCTUnwrap(record.capabilitiesJSON.data(using: .utf8))
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
            let secret = "token=super-secret-state-value"
            entries.insert(secret, at: 0)
            entries.insert(entries[entries.count - 2], at: entries.count - 1)
            let updatedData = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            let updatedJSON = try XCTUnwrap(String(data: updatedData, encoding: .utf8))
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "UPDATE observed_runtime_snapshots SET capabilities_json = ? WHERE id = ?",
                bindings: [.text(updatedJSON), .text(record.id)]
            )

            XCTAssertThrowsError(try select(store: store)) { error in
                XCTAssertEqual(
                    error as? RuntimeProviderSelectionError,
                    .invalidPersistedProviderMetadataEvidence
                )
                XCTAssertFalse(String(describing: error).contains(secret))
            }
        }
    }

    func testProductionContainerizationAdapterNameSelectsLatestAndRefusesNewerRevision() throws {
        try withStore { store, databaseURL in
            let snapshot = containerizationSnapshot()
            try seedProject(store, providerID: .appleContainerization)
            try saveSnapshot(
                store,
                id: "helper-production-adapter",
                providerID: .appleContainerization,
                runtimeAdapter: "AppleContainerizationRuntimeAdapter",
                digest: snapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:00:00Z"
            )

            let selected = try select(store: store, snapshot: snapshot)
            XCTAssertEqual(selected.selection.providerID, .appleContainerization)
            XCTAssertFalse(selected.selection.requiresReobservation)

            let record = try XCTUnwrap(
                try store.observedStates.loadLatestSnapshot(
                    projectID: projectID,
                    providerID: .appleContainerization
                )
            )
            XCTAssertEqual(record.runtimeAdapter, "AppleContainerizationRuntimeAdapter")
            let data = try XCTUnwrap(record.capabilitiesJSON.data(using: .utf8))
            var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
            entries[entries.count - 1] =
                RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "3"
            let updatedData = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
            let updatedJSON = try XCTUnwrap(String(data: updatedData, encoding: .utf8))
            let connection = try SQLiteConnection(path: databaseURL.path)
            try connection.run(
                "UPDATE observed_runtime_snapshots SET capabilities_json = ? WHERE id = ?",
                bindings: [.text(updatedJSON), .text(record.id)]
            )

            XCTAssertThrowsError(try select(store: store, snapshot: snapshot)) { error in
                XCTAssertEqual(
                    error as? RuntimeProviderSelectionError,
                    .unsupportedProviderMetadataDowngrade(
                        persistedRevision: 3,
                        currentRevision: 2
                    )
                )
            }
        }
    }

    func testH1EvidenceIsNotRewrittenUntilFreshObservationIsPersisted() throws {
        try withStore { store, databaseURL in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-h1",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: currentSnapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:00:00Z"
            )
            try replaceRevision(
                store: store,
                databaseURL: databaseURL,
                snapshotID: "cli-h1",
                revision: 1
            )

            let selected = try select(store: store)
            XCTAssertFalse(selected.selection.requiresReobservation)
            XCTAssertEqual(
                try persistedRevision(store: store, snapshotID: "cli-h1"),
                1
            )

            try saveSnapshot(
                store,
                id: "cli-h2-observation",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: currentSnapshot.canonicalSHA256,
                observedAt: "2026-07-19T12:01:00Z"
            )
            XCTAssertEqual(
                try persistedRevision(store: store, snapshotID: "cli-h2-observation"),
                2
            )
        }
    }

    private func select(
        store: SQLiteStateStore,
        snapshot: RuntimeCapabilitySnapshot? = nil
    ) throws -> HostwrightSelectedRuntimeProvider {
        try hostwrightSelectRuntimeProvider(
            requested: .automatic,
            store: store,
            projectID: projectID,
            requiredFeatures: [.observation],
            environment: environment(snapshot: snapshot ?? currentSnapshot)
        )
    }

    private func environment(snapshot: RuntimeCapabilitySnapshot) -> CLIEnvironment {
        let adapter = ScriptedRuntimeAdapter(scenario: .availableEmpty)
        let providerID = snapshot.descriptor.providerID
        return CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in throw CocoaError(.fileReadNoSuchFile) },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            runtimeAdapter: { adapter },
            runtimeAdapterForProvider: { requestedProviderID in
                guard requestedProviderID == providerID else {
                    throw RuntimeProviderSelectionError.providerUnavailable(requestedProviderID)
                }
                return adapter
            },
            runtimeProviderProbes: { [.available(snapshot)] },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS 26.0" }
        )
    }

    private func seedProject(
        _ store: SQLiteStateStore,
        providerID: RuntimeProviderID = .appleContainerCLI
    ) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(project: "demo", services: []),
            timestamp: "2026-07-19T11:00:00Z",
            mutationProvider: providerID.rawValue
        )
    }

    private func containerizationSnapshot() -> RuntimeCapabilitySnapshot {
        RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
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
                ],
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

    private func saveSnapshot(
        _ store: SQLiteStateStore,
        id: String,
        providerID: RuntimeProviderID,
        runtimeAdapter: String,
        digest: String?,
        observedAt: String
    ) throws {
        let metadata = providerID == .appleContainerCLI
            ? ScriptedRuntimeAdapter.defaultMetadata
            : RuntimeAdapterMetadata(
                providerID: providerID,
                adapterName: "helper-test-adapter",
                adapterVersion: "1",
                runtimeName: "helper-test-runtime",
                supportsMutation: true,
                capabilities: [.readOnlyObservation, .lifecycleMutation]
            )
        try store.observedStates.saveSnapshot(
            snapshotID: id,
            projectID: projectID,
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: metadata,
                capabilitySHA256: digest
            ),
            runtimeAdapter: runtimeAdapter,
            parserVersion: "cli-evidence-v1",
            rawOutputHash: nil,
            redactedSummary: "bounded summary",
            observedAt: observedAt
        )
    }

    private func replaceRevision(
        store: SQLiteStateStore,
        databaseURL: URL,
        snapshotID: String,
        revision: Int
    ) throws {
        let record = try XCTUnwrap(
            try store.observedStates.loadSnapshots(projectID: projectID).first {
                $0.id == snapshotID
            }
        )
        let data = try XCTUnwrap(record.capabilitiesJSON.data(using: .utf8))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
        entries[entries.count - 1] =
            RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + String(revision)
        let updated = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        let updatedJSON = try XCTUnwrap(String(data: updated, encoding: .utf8))
        let connection = try SQLiteConnection(path: databaseURL.path)
        try connection.run(
            "UPDATE observed_runtime_snapshots SET capabilities_json = ? WHERE id = ?",
            bindings: [.text(updatedJSON), .text(snapshotID)]
        )
    }

    private func persistedRevision(
        store: SQLiteStateStore,
        snapshotID: String
    ) throws -> Int {
        let record = try XCTUnwrap(
            try store.observedStates.loadSnapshots(projectID: projectID).first {
                $0.id == snapshotID
            }
        )
        return try RuntimeProviderMetadataEvidence.parse(
            capabilitiesJSON: record.capabilitiesJSON
        ).providerMetadataRevision
    }

    private func withStore(
        _ body: (SQLiteStateStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-provider-evidence-cli-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        let store = SQLiteStateStore(path: databaseURL.path)
        try store.migrate()
        try body(store, databaseURL)
    }
}
