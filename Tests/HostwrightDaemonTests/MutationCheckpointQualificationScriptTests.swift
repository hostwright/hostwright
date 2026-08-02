import Foundation
import XCTest

final class MutationCheckpointQualificationScriptTests: XCTestCase {
    func testContractIsSerialResumableAndNonDisruptive() throws {
        let scriptURL = packageRoot().appendingPathComponent(
            "scripts/phase08-mutation-checkpoint-qualification.sh"
        )
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "contract"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertTrue(
            text.contains(
                "Phase 08 mutation checkpoint qualification contract v1 is valid."
            )
        )
        for fragment in [
            "Cells run serially",
            "exact source digest",
            "LifecycleProcessRecoveryIntegrationTests",
            "HostwrightDaemonCoreTests",
            "RuntimeQualificationRecoveryDriverTests",
            "RuntimeQualificationProcessControlTests",
            "ServiceTunnelLifecycleManagerTests",
            "StoragePruneProcessRecoveryIntegrationTests",
            "SQLiteHardeningTests",
            "StorageAttachmentCoordinatorTests",
            "StateMaintenanceTests",
            "RuntimeProviderMigrationTests",
            "DaemonLifecycleContractTests",
            "DistributionDurableLifecycleTests",
            "HostwrightCLITests",
            "MutationCheckpointQualificationScriptTests"
        ] {
            XCTAssertTrue(text.contains(fragment), "Missing cell: \(fragment)")
        }
        XCTAssertTrue(script.contains("active-run-v1"))
        XCTAssertTrue(script.contains("grep -Fqx"))
        XCTAssertTrue(
            script.contains(
                "rmdir \"$HOSTWRIGHT_PHASE08_CHECKPOINT_ROOT/active-run-v1\""
            )
        )
        XCTAssertTrue(script.contains("cell-${index}.log.XXXXXX"))
        XCTAssertTrue(script.contains("umask 022 && swift test"))
        XCTAssertFalse(script.contains("swift test &"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("/sbin/reboot"))
        XCTAssertFalse(script.contains("/sbin/shutdown"))
        XCTAssertFalse(script.contains("launchctl"))
        XCTAssertFalse(script.contains("gh "))
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
