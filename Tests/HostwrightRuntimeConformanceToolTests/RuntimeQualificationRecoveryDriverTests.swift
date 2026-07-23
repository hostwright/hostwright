import CryptoKit
import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightState
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationRecoveryDriverTests: XCTestCase {
    func testHelperSignatureVerifierRequiresExactProductionIdentity() {
        XCTAssertTrue(RuntimeQualificationHelperSignatureVerifier.matchesExpectedIdentity(
            teamIdentifier: ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier,
            identifier: "hostwright-containerization-helper"
        ))
        XCTAssertFalse(RuntimeQualificationHelperSignatureVerifier.matchesExpectedIdentity(
            teamIdentifier: ContainerizationHelperPeerIdentityPolicy.expectedTeamIdentifier,
            identifier: "dev.hostwright.containerization-helper"
        ))
        XCTAssertFalse(RuntimeQualificationHelperSignatureVerifier.matchesExpectedIdentity(
            teamIdentifier: "AAAAAAAAAA",
            identifier: "hostwright-containerization-helper"
        ))
        XCTAssertFalse(RuntimeQualificationHelperSignatureVerifier.matchesExpectedIdentity(
            teamIdentifier: nil,
            identifier: nil
        ))
    }

    func testHelperSignatureVerifierRejectsUnsignedAndWrongSignerExecutables() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("hostwright-containerization-helper")

        try Data("#!/bin/sh\nexit 0\n".utf8).write(
            to: helper,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        XCTAssertThrowsError(try RuntimeQualificationHelperSignatureVerifier.sha256(of: helper)) {
            XCTAssertEqual(
                $0 as? RuntimeQualificationRecoveryDriverError,
                .providerPreflightFailed
            )
        }

        try FileManager.default.removeItem(at: helper)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: helper
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helper.path
        )
        XCTAssertThrowsError(try RuntimeQualificationHelperSignatureVerifier.sha256(of: helper)) {
            XCTAssertEqual(
                $0 as? RuntimeQualificationRecoveryDriverError,
                .providerPreflightFailed
            )
        }
    }

    func testInstalledHelperTransitionUsesOneFixedSlotAndExactCleans() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try executable(named: "prior", contents: "h1", under: root)
        let installed = try executable(named: "installed", contents: "h2", under: root)
        let transition = try RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )
        XCTAssertEqual(
            transition.stagedURL.deletingLastPathComponent().lastPathComponent,
            ".hostwright-phase03-helper-upgrade"
        )

        try transition.activatePrior()
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "h1")
        XCTAssertEqual(try String(contentsOf: transition.stagedURL, encoding: .utf8), "h2")

        try transition.restoreCurrent()
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "h2")
        XCTAssertEqual(try String(contentsOf: transition.stagedURL, encoding: .utf8), "h1")
        try transition.removeStaging()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: transition.stagedURL.deletingLastPathComponent().path
        ))
    }

    func testInstalledHelperTransitionRestoresAfterInterruptedPriorSlot() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try executable(named: "prior", contents: "h1", under: root)
        let installed = try executable(named: "installed", contents: "h2", under: root)
        var interrupted: RuntimeQualificationInstalledHelperTransition? = try
            RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )
        try interrupted?.activatePrior()
        let interruptedStagedURL = try XCTUnwrap(interrupted?.stagedURL)
        interrupted = nil

        let resumed = try RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )

        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "h2")
        XCTAssertEqual(try String(contentsOf: resumed.stagedURL, encoding: .utf8), "h1")
        XCTAssertEqual(resumed.stagedURL, interruptedStagedURL)
        try resumed.removeStaging()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumed.stagedURL.path))
    }

    func testInstalledHelperTransitionRefusesConcurrentFixedSlotUse() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try executable(named: "prior", contents: "h1", under: root)
        let installed = try executable(named: "installed", contents: "h2", under: root)
        let active = try RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )

        XCTAssertThrowsError(try RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )) {
            XCTAssertEqual(
                $0 as? RuntimeQualificationRecoveryDriverError,
                .providerPreflightFailed
            )
        }
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "h2")
        XCTAssertEqual(try String(contentsOf: active.stagedURL, encoding: .utf8), "h1")
        try active.removeStaging()
    }

    func testInstalledHelperTransitionRejectsTamperedStagingBeforeSwap() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prior = try executable(named: "prior", contents: "h1", under: root)
        let installed = try executable(named: "installed", contents: "h2", under: root)
        let transition = try RuntimeQualificationInstalledHelperTransition.prepare(
            priorURL: prior,
            installedURL: installed,
            priorSHA256: digest("h1"),
            currentSHA256: digest("h2")
        )
        try Data("tampered".utf8).write(to: transition.stagedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: transition.stagedURL.path
        )

        XCTAssertThrowsError(try transition.activatePrior())
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "h2")
    }

    func testSpecificationAcceptsOnlyLockedProviderScenarioPairs() throws {
        for scenario in RuntimeQualificationRecoveryScenario.allCases {
            let provider: RuntimeProviderID = switch scenario {
            case .helperRestart, .staleHelper: .appleContainerization
            default: .appleContainerCLI
            }
            let version = provider == .appleContainerCLI ? "1.1.0" : "0.35.0"
            XCTAssertNoThrow(try RuntimeQualificationRecoverySpecification(
                providerID: provider,
                expectedVersion: version,
                scenario: scenario,
                localImage: "example.local/runtime@sha256:\(digest("image"))",
                priorHelperURL: scenario == .staleHelper
                    ? URL(fileURLWithPath: "/signed-h1/hostwright-containerization-helper")
                    : nil
            ).validated())
        }
        XCTAssertThrowsError(try RuntimeQualificationRecoverySpecification(
            providerID: .appleContainerization,
            expectedVersion: "0.35.0",
            scenario: .cliServiceRestart,
            localImage: "example.local/runtime:latest"
        ).validated())
        XCTAssertThrowsError(try RuntimeQualificationRecoverySpecification(
            providerID: .appleContainerization,
            expectedVersion: "0.35.0",
            scenario: .staleHelper,
            localImage: "example.local/runtime:latest"
        ).validated())
        XCTAssertThrowsError(try RuntimeQualificationRecoverySpecification(
            providerID: .appleContainerization,
            expectedVersion: "0.35.0",
            scenario: .helperRestart,
            localImage: "example.local/runtime:latest",
            priorHelperURL: URL(
                fileURLWithPath: "/signed-h1/hostwright-containerization-helper"
            )
        ).validated())
        XCTAssertThrowsError(try RuntimeQualificationRecoverySpecification(
            providerID: .appleContainerCLI,
            expectedVersion: "1.2.0",
            scenario: .checkpointCrash,
            localImage: "example.local/runtime:latest"
        ).validated())
    }

    func testFreshWorkerResumesDurableSchemaV7Checkpoint() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.sqlite")
        let signal = directory.appendingPathComponent("resumer.ready")
        let marker = directory.appendingPathComponent(".hostwright-phase03-owned")
        try Data((UUID().uuidString.lowercased() + "\n").utf8).write(
            to: marker, options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: marker.path
        )
        let groupID = UUID().uuidString.lowercased()
        let fence = UUID().uuidString.lowercased()
        let store = SQLiteStateStore(path: database.path)
        try store.migrate()
        let timestamp = "2026-07-19T12:00:00Z"
        let acquired = try store.operationGroups.acquire(OperationGroupRecord(
            id: groupID,
            operationID: UUID().uuidString.lowercased(),
            groupKind: "phase03-recovery",
            projectID: nil,
            serviceName: nil,
            plannedActionType: "recovery-qualification",
            status: .active,
            groupIdempotencyKey: "phase03-recovery-\(groupID)",
            planHash: digest(groupID),
            checkpoint: "runtime-effect-recorded",
            lockOwner: "hostwright-runtime-conformance",
            lockExpiresAt: "2999-01-01T00:00:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "Resume.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: "{}",
            fencingToken: fence,
            intentJSONRedacted: "{}",
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{\"durable\":true}"
        ))
        XCTAssertEqual(acquired.acquired?.id, groupID)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        let databaseAttributes = try FileManager.default.attributesOfItem(atPath: database.path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
        XCTAssertEqual(markerAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(markerAttributes[.referenceCount] as? NSNumber, 1)
        XCTAssertEqual(databaseAttributes[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertEqual(databaseAttributes[.referenceCount] as? NSNumber, 1)

        let result = RuntimeQualificationRecoveryWorker.runIfRequested(arguments: [
            "hostwright-runtime-conformance",
            "__phase03-recovery-worker", "resume", database.path, groupID, fence,
            "runtime-effect-recorded", "recovered-after-checkpoint-crash", signal.path,
        ])
        XCTAssertEqual(result, 0)
        let freshStore = SQLiteStateStore(path: database.path)
        XCTAssertEqual(try freshStore.schemaVersion(), 7)
        let recovered = try XCTUnwrap(try freshStore.operationGroups.load(id: groupID))
        XCTAssertEqual(recovered.status, .succeeded)
        XCTAssertEqual(recovered.checkpoint, "recovered-after-checkpoint-crash")
        XCTAssertEqual(recovered.fencingToken, fence)
        XCTAssertEqual(try String(contentsOf: signal, encoding: .utf8), "ready\n")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: signal.path)[.posixPermissions] as? NSNumber, 0o600)
    }

    func testWorkerRejectsUnsafeOrIncompleteInvocationWithoutWriting() {
        XCTAssertEqual(RuntimeQualificationRecoveryWorker.runIfRequested(arguments: [
            "hostwright-runtime-conformance", "__phase03-recovery-worker", "resume",
        ]), 64)
        XCTAssertNil(RuntimeQualificationRecoveryWorker.runIfRequested(arguments: [
            "hostwright-runtime-conformance", "--version",
        ]))
    }

    func testWriterIsKilledAndFreshExecutableResumesItsDurableCheckpoint() async throws {
        let foundation = try RuntimeQualificationRecoveryStateFoundation.make(
            checkpoint: "runtime-effect-recorded"
        )
        defer { try? foundation.remove() }
        let executable = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("hostwright-runtime-conformance")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let recorder = RuntimeQualificationCommandRecorder()
        let terminated = try await RuntimeQualificationRecoveryProcessCycle.run(
            foundation: foundation,
            resumedCheckpoint: "recovered-after-checkpoint-crash",
            recorder: recorder,
            executableURL: executable
        )
        XCTAssertEqual(terminated, "hostwright-runtime-conformance")
        let recovered = try foundation.verifyRecovered(
            to: "recovered-after-checkpoint-crash"
        )
        XCTAssertEqual(recovered.before, "runtime-effect-recorded")
        XCTAssertEqual(recovered.after, "recovered-after-checkpoint-crash")
        XCTAssertEqual(recovered.schema, 7)
        let commands = try await recorder.evidence()
        XCTAssertEqual(commands.map(\.exitStatus), [-1, 0])
        XCTAssertEqual(
            commands.map { $0.arguments.last },
            ["recovery-worker-write", "recovery-worker-resume"]
        )
    }

    func testUnmanagedDigestExcludesMachineMetadataDrift() throws {
        let before = try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.5",
                architecture: "arm64",
                runtimeVersion: "1.0.0",
                services: []
            ),
            containers: [],
            images: [],
            networks: [],
            volumes: []
        )
        let after = try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.5",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: [],
            images: [],
            networks: [],
            volumes: []
        )

        XCTAssertNotEqual(before.semanticSHA256, after.semanticSHA256)
        XCTAssertEqual(
            try RuntimeQualificationUnmanagedInventoryDigest.sha256(before),
            try RuntimeQualificationUnmanagedInventoryDigest.sha256(after)
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-phase03-recovery-\(UUID().uuidString)", isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func executable(
        named directoryName: String,
        contents: String,
        under root: URL
    ) throws -> URL {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("hostwright-containerization-helper")
        try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
