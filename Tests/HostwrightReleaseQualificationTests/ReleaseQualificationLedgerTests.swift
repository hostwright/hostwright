import Foundation
import XCTest
import HostwrightCore
@testable import HostwrightReleaseQualification

final class ReleaseQualificationLedgerTests: XCTestCase {
    func testReplayConflictRecoveryAndCancellation() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ReleaseQualificationLedgerStore(root: root.appendingPathComponent("ledger"))
        let environment = ReleaseQualificationTestSupport.environment()
        let claim = ReleaseQualificationTestSupport.claim()
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: environment.commands
        )
        XCTAssertEqual(
            try ledger.begin(runID: "run-one", claim: claim, replayKey: replayKey),
            .created
        )
        XCTAssertEqual(
            try ledger.begin(runID: "run-one", claim: claim, replayKey: replayKey),
            .replayed
        )
        XCTAssertThrowsError(
            try ledger.begin(
                runID: "run-one",
                claim: ReleaseQualificationTestSupport.claim(
                    cell: ReleaseQualificationSupportedMatrix.committed.cells[1]
                ),
                replayKey: replayKey
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseQualificationContractError, .ledgerConflict)
        }
        XCTAssertEqual(try ledger.recover(), ["run-one"])
        XCTAssertEqual(
            try ledger.begin(runID: "run-one", claim: claim, replayKey: replayKey),
            .recovered
        )
        try ledger.cancel(runID: "run-one")
        XCTAssertEqual(
            try ledger.begin(runID: "run-one", claim: claim, replayKey: replayKey),
            .replayed
        )

        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try ledger.begin(
                runID: "run-two",
                claim: claim,
                replayKey: replayKey,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseQualificationContractError, .cancelled)
        }
    }

    func testEvidenceCompletionRejectsTamperAndStaleEnvironment() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ReleaseQualificationLedgerStore(root: root.appendingPathComponent("ledger"))
        let environment = ReleaseQualificationTestSupport.environment()
        let claim = ReleaseQualificationTestSupport.claim()
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: environment.commands
        )
        _ = try ledger.begin(runID: "evidence-run", claim: claim, replayKey: replayKey)
        var evidence = try ReleaseQualificationTestSupport.evidence(
            environment: environment,
            runID: "evidence-run"
        )
        evidence = ReleaseQualificationEvidence(
            runID: evidence.runID,
            claim: evidence.claim,
            evidenceClass: evidence.evidenceClass,
            status: evidence.status,
            simulation: evidence.simulation,
            source: evidence.source,
            environment: evidence.environment,
            startedAt: evidence.startedAt,
            endedAt: evidence.endedAt,
            durationMilliseconds: evidence.durationMilliseconds,
            commands: evidence.commands,
            rawOutputSHA256: evidence.rawOutputSHA256,
            artifacts: evidence.artifacts,
            blockers: evidence.blockers,
            failures: evidence.failures,
            replayKey: replayKey
        )
        XCTAssertEqual(
            try ledger.complete(runID: "evidence-run", evidence: evidence),
            .created
        )
        XCTAssertEqual(
            try ledger.verifyCurrent(runID: "evidence-run", environment: environment),
            evidence
        )
        XCTAssertThrowsError(
            try ledger.verifyCurrent(
                runID: "evidence-run",
                environment: ReleaseQualificationTestSupport.environment(
                    source: ReleaseQualificationTestSupport.source(dirty: true)
                )
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseQualificationContractError, .staleEvidence)
        }

        let journalURL = root
            .appendingPathComponent("ledger/journals/evidence-run.json")
        var journalData = try Data(contentsOf: journalURL)
        journalData.append(Data("tamper".utf8))
        try journalData.write(to: journalURL, options: [.atomic])
        XCTAssertThrowsError(try ledger.journal(runID: "evidence-run"))
    }

    func testArtifactCleanupRemovesOnlyOwnedExactArtifacts() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ReleaseQualificationLedgerStore(root: root.appendingPathComponent("ledger"))
        let artifact = try ledger.publishArtifact(
            data: Data("owned".utf8),
            relativePath: "nested/owned.bin",
            retention: .removeOnCleanup
        )
        let unmanaged = root.appendingPathComponent(
            "ledger/artifacts/unmanaged.bin"
        )
        try Data("unmanaged".utf8).write(to: unmanaged, options: [.atomic])
        let environment = ReleaseQualificationTestSupport.environment()
        let claim = ReleaseQualificationTestSupport.claim()
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: environment.commands
        )
        _ = try ledger.begin(runID: "cleanup-run", claim: claim, replayKey: replayKey)
        let evidence = try ReleaseQualificationTestSupport.evidence(
            environment: environment,
            artifacts: [artifact],
            runID: "cleanup-run"
        )
        _ = try ledger.complete(runID: "cleanup-run", evidence: evidence)
        XCTAssertEqual(try ledger.cleanup(runID: "cleanup-run"), ["nested/owned.bin"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("ledger/artifacts/nested/owned.bin").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmanaged.path))
    }

    func testArtifactSymlinkParentIsRejected() throws {
        let root = try ReleaseQualificationTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try ReleaseQualificationLedgerStore(root: root.appendingPathComponent("ledger"))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let link = root.appendingPathComponent("ledger/artifacts/link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try ledger.publishArtifact(
                data: Data("unsafe".utf8),
                relativePath: "link/escape.bin"
            )
        )

        let token = String(repeating: "b", count: 32)
        let escape = outside.appendingPathComponent("escape.bin")
        let escapeData = Data("unmanaged".utf8)
        try escapeData.write(to: escape, options: [.atomic])
        try Data(token.utf8).write(
            to: outside.appendingPathComponent(".hostwright-owner-\(token)"),
            options: [.atomic]
        )
        let artifact = ReleaseQualificationOwnedArtifact(
            relativePath: "link/escape.bin",
            sha256: ReleaseQualificationHash.sha256(data: escapeData),
            sizeBytes: escapeData.count,
            retention: .removeOnCleanup,
            ownershipToken: token
        )
        let environment = ReleaseQualificationTestSupport.environment()
        let claim = ReleaseQualificationTestSupport.claim()
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: environment,
            commands: environment.commands
        )
        _ = try ledger.begin(
            runID: "cleanup-symlink",
            claim: claim,
            replayKey: replayKey
        )
        let evidence = try ReleaseQualificationTestSupport.evidence(
            environment: environment,
            artifacts: [artifact],
            runID: "cleanup-symlink"
        )
        _ = try ledger.complete(runID: "cleanup-symlink", evidence: evidence)
        XCTAssertThrowsError(try ledger.cleanup(runID: "cleanup-symlink"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: escape.path))
    }
}
