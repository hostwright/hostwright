import Foundation
import HostwrightCore
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
        XCTAssertEqual(repeated.status, 64, repeated.output)

        let malformed = try runContract(
            script: script,
            baselineRelease: "main",
            candidateRelease: String(repeating: "b", count: 40),
            baselineTap: String(repeating: "c", count: 40),
            candidateTap: String(repeating: "d", count: 40)
        )
        XCTAssertEqual(malformed.status, 64, malformed.output)

        let ambiguous = try runContract(
            script: script,
            baselineRelease: String(repeating: "a", count: 40),
            candidateRelease: String(repeating: "b", count: 40),
            baselineTap: String(repeating: "c", count: 40),
            candidateTap: String(repeating: "d", count: 40),
            environmentOverrides: ["HOSTWRIGHT_TEST_RESULTS_DIR": "/tmp/canonical-junit-output"]
        )
        XCTAssertEqual(ambiguous.status, 64, ambiguous.output)
        XCTAssertTrue(ambiguous.output.contains("Ambiguous qualification environment override: HOSTWRIGHT_TEST_RESULTS_DIR"))
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
        candidateTap: String,
        environmentOverrides: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "validate-contract"]
        process.standardOutput = pipe
        process.standardError = pipe
        var environment = SecureSubprocessEnvironment.minimal
        environment["HOSTWRIGHT_BASELINE_RELEASE_COMMIT"] = baselineRelease
        environment["HOSTWRIGHT_CANDIDATE_RELEASE_COMMIT"] = candidateRelease
        environment["HOSTWRIGHT_BASELINE_TAP_COMMIT"] = baselineTap
        environment["HOSTWRIGHT_CANDIDATE_TAP_COMMIT"] = candidateTap
        environment.merge(environmentOverrides) { _, explicit in explicit }
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
}
