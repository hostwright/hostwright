import Foundation
@testable import HostwrightDistribution
import XCTest

final class DistributionLifecycleModelsTests: XCTestCase {
    func testLifecycleJournalAndStatusArePathBoundCanonicalContracts() throws {
        let prefix = "/Users/example/hostwright-dist-prefix-contract"
        let operationID = UUID().uuidString.lowercased()
        let installed = installManifest(version: "0.0.1", commitByte: "a")
        let candidate = installManifest(version: "0.0.2-dev", commitByte: "b")
        let transaction = ".hostwright-lifecycle/transactions/\(operationID)"
        let priorStatus = DistributionInstallationStatus(
            installationID: UUID().uuidString.lowercased(),
            generation: 1,
            prefix: prefix,
            installedManifest: installed,
            stateDatabasePath: nil,
            service: .notInstalled,
            rollbackOperationID: nil,
            updatedAt: "2026-07-14T16:59:00Z"
        )
        let snapshot = DistributionStateSnapshotRecord(
            databasePath: "/Users/example/Library/Application Support/Hostwright/state/state.sqlite",
            snapshotRelativePath: "\(transaction)/state/state.sqlite",
            databaseSHA256: String(repeating: "c", count: 64),
            databaseBytes: 4_096,
            stateSchemaVersion: 6
        )
        let journal = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .upgrade,
            checkpoint: .stateBackedUp,
            prefix: prefix,
            transactionRelativePath: transaction,
            fromManifest: installed,
            toManifest: candidate,
            stateSnapshot: snapshot,
            serviceBefore: .notInstalled,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T17:00:00Z",
            priorStatus: priorStatus
        )
        XCTAssertNoThrow(try journal.validate())

        let encoded = try DistributionJSON.encode(journal)
        let decoded = try JSONDecoder().decode(DistributionLifecycleJournal.self, from: encoded)
        XCTAssertEqual(decoded, journal)
        XCTAssertEqual(try DistributionJSON.encode(decoded), encoded)

        let status = DistributionInstallationStatus(
            installationID: UUID().uuidString.lowercased(),
            generation: 2,
            prefix: prefix,
            installedManifest: candidate,
            stateDatabasePath: snapshot.databasePath,
            service: .notInstalled,
            rollbackOperationID: operationID,
            updatedAt: "2026-07-14T17:01:00Z"
        )
        XCTAssertNoThrow(try status.validate())

        let unsafe = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .upgrade,
            checkpoint: .intentRecorded,
            prefix: prefix,
            transactionRelativePath: "../outside",
            fromManifest: installed,
            toManifest: candidate,
            stateSnapshot: nil,
            serviceBefore: .notInstalled,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T17:00:00Z",
            priorStatus: priorStatus
        )
        XCTAssertThrowsError(try unsafe.validate())
    }

    func testLifecycleJournalRejectsInvalidOperationShapeAndUnverifiedRollback() throws {
        let prefix = "/Users/example/hostwright-dist-prefix-contract"
        let operationID = UUID().uuidString.lowercased()
        let installed = installManifest(version: "0.0.1", commitByte: "a")
        let candidate = installManifest(version: "0.0.2-dev", commitByte: "b")
        let transaction = ".hostwright-lifecycle/transactions/\(operationID)"
        let priorStatus = DistributionInstallationStatus(
            installationID: UUID().uuidString.lowercased(),
            generation: 1,
            prefix: prefix,
            installedManifest: installed,
            stateDatabasePath: nil,
            service: .notInstalled,
            rollbackOperationID: nil,
            updatedAt: "2026-07-14T16:59:00Z"
        )

        let installWithPriorState = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .install,
            checkpoint: .intentRecorded,
            prefix: prefix,
            transactionRelativePath: transaction,
            fromManifest: installed,
            toManifest: candidate,
            stateSnapshot: nil,
            serviceBefore: .notInstalled,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T17:00:00Z",
            priorStatus: priorStatus
        )
        XCTAssertThrowsError(try installWithPriorState.validate())

        let arbitraryRollback = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .rollback,
            checkpoint: .intentRecorded,
            prefix: prefix,
            transactionRelativePath: transaction,
            fromManifest: candidate,
            toManifest: installed,
            stateSnapshot: nil,
            serviceBefore: .notInstalled,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T17:00:00Z",
            authorizedRollbackOperationID: nil,
            priorStatus: priorStatus
        )
        XCTAssertThrowsError(try arbitraryRollback.validate())
    }

    func testLifecycleContractsAllowBoundManagedServiceStatesAndRejectUnboundCheckpoints() throws {
        let manifest = installManifest(version: "0.0.1", commitByte: "a")
        let prefix = "/tmp/hostwright-dist-service-contract"
        let status = DistributionInstallationStatus(
            installationID: UUID().uuidString.lowercased(),
            generation: 1,
            prefix: prefix,
            installedManifest: manifest,
            stateDatabasePath: nil,
            service: .running,
            rollbackOperationID: nil,
            updatedAt: "2026-07-14T18:00:00Z"
        )

        XCTAssertNoThrow(try status.validate())
        let operationID = UUID().uuidString.lowercased()
        let journal = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .install,
            checkpoint: .intentRecorded,
            prefix: prefix,
            transactionRelativePath: ".hostwright-lifecycle/transactions/\(operationID)",
            fromManifest: nil,
            toManifest: manifest,
            stateSnapshot: nil,
            serviceBefore: .stopped,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T18:00:00Z"
        )
        XCTAssertNoThrow(try journal.validate())

        let invalidServiceCheckpoint = DistributionLifecycleJournal(
            operationID: operationID,
            operation: .install,
            checkpoint: .serviceStopped,
            prefix: prefix,
            transactionRelativePath: ".hostwright-lifecycle/transactions/\(operationID)",
            fromManifest: nil,
            toManifest: manifest,
            stateSnapshot: nil,
            serviceBefore: .stopped,
            dataPolicy: .preserve,
            startedAt: "2026-07-14T18:00:00Z"
        )
        XCTAssertThrowsError(try invalidServiceCheckpoint.validate())
    }

    private func installManifest(version: String, commitByte: Character) -> DistributionInstallManifest {
        let commit = String(repeating: String(commitByte), count: 40)
        return DistributionInstallManifest(
            artifact: DistributionArtifactManifest(
                artifactID: "hostwright-\(version)-macos-arm64-\(commit.prefix(12))",
                packageVersion: version,
                sourceCommit: commit,
                sourceDirty: false,
                architecture: "arm64",
                createdAt: "2026-07-14T16:00:00Z",
                files: DistributionLayout.payloadModes.keys.sorted().map { path in
                    DistributionFileRecord(
                        path: path,
                        sha256: String(repeating: "d", count: 64),
                        sizeBytes: 1,
                        mode: DistributionLayout.payloadModes[path]!
                    )
                }
            ),
            createdDirectories: []
        )
    }
}
