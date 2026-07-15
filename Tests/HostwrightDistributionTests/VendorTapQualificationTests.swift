import Foundation
import XCTest

final class VendorTapQualificationTests: XCTestCase {
    func testQualificationContractAcceptsOnlyDistinctExactCommits() throws {
        let script = packageRoot().appendingPathComponent("scripts/release/qualify-vendor-tap.sh")
        let valid = try runContract(
            script: script,
            baselineRelease: String(repeating: "a", count: 40),
            candidateRelease: String(repeating: "b", count: 40),
            baselineTap: String(repeating: "c", count: 40),
            candidateTap: String(repeating: "d", count: 40)
        )
        XCTAssertEqual(valid.status, 0, valid.output)
        XCTAssertTrue(valid.output.contains("contract is valid"))

        let repeated = try runContract(
            script: script,
            baselineRelease: String(repeating: "a", count: 40),
            candidateRelease: String(repeating: "a", count: 40),
            baselineTap: String(repeating: "c", count: 40),
            candidateTap: String(repeating: "d", count: 40)
        )
        XCTAssertNotEqual(repeated.status, 0)

        let malformed = try runContract(
            script: script,
            baselineRelease: "main",
            candidateRelease: String(repeating: "b", count: 40),
            baselineTap: String(repeating: "c", count: 40),
            candidateTap: String(repeating: "d", count: 40)
        )
        XCTAssertNotEqual(malformed.status, 0)
    }

    func testReleaseWorkflowLocksTheTwoImmutableQualificationBuilds() throws {
        let workflow = try read(".github/workflows/trusted-release.yml")

        XCTAssertTrue(workflow.contains("default: 0.0.2-dev.1"))
        XCTAssertTrue(workflow.contains("default: v0.0.2-dev.1"))
        XCTAssertTrue(workflow.contains(#"^0\.0\.2-dev\.[12]$"#))
        XCTAssertTrue(workflow.contains("github.ref == 'refs/heads/main'"))
        XCTAssertTrue(workflow.contains("name: Validate reviewed release inputs"))
        XCTAssertTrue(workflow.contains("needs: validate"))
        XCTAssertTrue(workflow.contains("refs/tags/v0.0.2-dev.1^{}"))
        XCTAssertTrue(workflow.contains("git merge-base --is-ancestor \"$baseline_commit\" \"$RELEASE_COMMIT\""))
        XCTAssertTrue(workflow.contains("swift run hostwright --version"))
        XCTAssertTrue(workflow.contains("contracts/v0.0.2/versions.json"))
        XCTAssertFalse(workflow.contains("0.0.2-dev\n        type: string"))
    }

    func testCleanHostWorkflowIsProtectedResumableAndReadOnly() throws {
        let workflow = try read(".github/workflows/vendor-tap-qualification.yml")
        let script = try read("scripts/release/qualify-vendor-tap.sh")

        XCTAssertTrue(workflow.contains("github.ref == 'refs/heads/main'"))
        XCTAssertTrue(workflow.contains("runs-on: [self-hosted, macOS, ARM64, hostwright-clean-install]"))
        XCTAssertTrue(workflow.contains("environment: release"))
        XCTAssertTrue(workflow.contains("attestations: read"))
        XCTAssertFalse(workflow.contains("contents: write"))

        for fragment in [
            "0.0.2-dev.1",
            "0.0.2-dev.2",
            "reboot-required",
            "A real reboot has not occurred",
            "brew upgrade \"$formula_reference\"",
            "brew services restart",
            "gh attestation verify",
            "write_state preparing \"$boot\" \"$config_path\" \"$config_digest\"",
            "validate_qualification_install",
            "validate_existing_tap",
            "stage-$command-failed-exit-$status",
            "Homebrew removed or changed user configuration during uninstall",
            "brew untap \"$tap_name\""
        ] {
            XCTAssertTrue(script.contains(fragment), "Missing qualification contract: \(fragment)")
        }
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("brew install hostwright\n"))
        XCTAssertFalse(script.contains("brew install hostwright\r\n"))
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(path), encoding: .utf8)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func runContract(
        script: URL,
        baselineRelease: String,
        candidateRelease: String,
        baselineTap: String,
        candidateTap: String
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "validate-contract"]
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["HOSTWRIGHT_BASELINE_RELEASE_COMMIT"] = baselineRelease
        environment["HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"] = candidateRelease
        environment["HOSTWRIGHT_BASELINE_TAP_COMMIT"] = baselineTap
        environment["HOSTWRIGHT_CANDIDATE_TAP_COMMIT"] = candidateTap
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
