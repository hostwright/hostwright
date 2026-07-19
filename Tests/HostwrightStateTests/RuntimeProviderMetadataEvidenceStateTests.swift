import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightRuntime
@testable import HostwrightState

final class RuntimeProviderMetadataEvidenceStateTests: XCTestCase {
    private let projectID = "project-demo"

    func testSchemaV7SnapshotPersistsCapabilitiesAsStringArrayWithReservedEvidenceSuffix() throws {
        try withStore { store in
            let digest = String(repeating: "a", count: 64)
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "snapshot-evidence",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: digest,
                observedAt: "2026-07-19T12:00:00Z"
            )

            XCTAssertEqual(try store.schemaVersion(), 7)
            let record = try XCTUnwrap(try store.observedStates.loadSnapshots(projectID: projectID).first)
            let data = try XCTUnwrap(record.capabilitiesJSON.data(using: .utf8))
            let entries = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String]
            )
            XCTAssertEqual(
                Array(entries.dropLast(2)),
                [
                    RuntimeCapability.lifecycleMutation.rawValue,
                    RuntimeCapability.readOnlyObservation.rawValue
                ].sorted()
            )
            XCTAssertEqual(
                Array(entries.suffix(2)),
                [
                    RuntimeProviderMetadataEvidence.capabilitySHA256MarkerPrefix + digest,
                    RuntimeProviderMetadataEvidence.providerMetadataRevisionMarkerPrefix + "2"
                ]
            )
            let evidence = try RuntimeProviderMetadataEvidence.parse(
                capabilitiesJSON: record.capabilitiesJSON
            )
            XCTAssertEqual(evidence.capabilitySHA256, digest)
            XCTAssertEqual(evidence.providerMetadataRevision, 2)
            XCTAssertFalse(evidence.isLegacy)
        }
    }

    func testLegacySnapshotWithoutReservedMarkersDefaultsToRevisionOne() throws {
        try withStore { store in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "snapshot-legacy",
                providerID: .appleContainerCLI,
                runtimeAdapter: "AppleContainerReadOnlyAdapter",
                digest: nil,
                observedAt: "2026-07-19T12:00:00Z"
            )

            let record = try XCTUnwrap(try store.observedStates.loadSnapshots(projectID: projectID).first)
            let evidence = try RuntimeProviderMetadataEvidence.parse(
                capabilitiesJSON: record.capabilitiesJSON
            )
            XCTAssertTrue(evidence.isLegacy)
            XCTAssertEqual(evidence.providerMetadataRevision, 1)
            XCTAssertNil(evidence.capabilitySHA256)
            XCTAssertFalse(record.capabilitiesJSON.contains("hostwright.provider-"))
        }
    }

    func testLatestSnapshotFiltersMixedHistoryByStableProviderIdentity() throws {
        try withStore { store in
            try seedProject(store)
            try saveSnapshot(
                store,
                id: "cli-old",
                providerID: .appleContainerCLI,
                runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
                digest: String(repeating: "a", count: 64),
                observedAt: "2026-07-19T12:00:00Z"
            )
            try saveSnapshot(
                store,
                id: "cli-new-alias",
                providerID: .appleContainerCLI,
                runtimeAdapter: "AppleContainerReadOnlyAdapter",
                digest: String(repeating: "b", count: 64),
                observedAt: "2026-07-19T12:02:00Z"
            )
            try saveSnapshot(
                store,
                id: "helper-newest-overall",
                providerID: .appleContainerization,
                runtimeAdapter: "AppleContainerizationRuntimeAdapter",
                digest: String(repeating: "c", count: 64),
                observedAt: "2026-07-19T12:03:00Z"
            )

            XCTAssertEqual(
                try store.observedStates.loadLatestSnapshot(
                    projectID: projectID,
                    providerID: .appleContainerCLI
                )?.id,
                "cli-new-alias"
            )
            XCTAssertEqual(
                try store.observedStates.loadLatestSnapshot(
                    projectID: projectID,
                    providerID: .appleContainerization
                )?.id,
                "helper-newest-overall"
            )
        }
    }

    private func seedProject(_ store: SQLiteStateStore) throws {
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID,
            manifestPath: "hostwright.yaml",
            manifestHash: "manifest-hash",
            desiredGeneration: 1,
            manifest: HostwrightManifest(project: "demo", services: []),
            timestamp: "2026-07-19T11:00:00Z",
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue
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
        try store.observedStates.saveSnapshot(
            snapshotID: id,
            projectID: projectID,
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [],
                adapterMetadata: RuntimeAdapterMetadata(
                    providerID: providerID,
                    adapterName: "state-evidence-test",
                    adapterVersion: "1",
                    runtimeName: "state-evidence-runtime",
                    supportsMutation: true,
                    capabilities: [.readOnlyObservation, .lifecycleMutation]
                ),
                capabilitySHA256: digest
            ),
            runtimeAdapter: runtimeAdapter,
            parserVersion: "state-evidence-v1",
            rawOutputHash: nil,
            redactedSummary: "bounded summary",
            observedAt: observedAt
        )
    }

    private func withStore(_ body: (SQLiteStateStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-provider-evidence-state-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        try body(store)
    }
}
