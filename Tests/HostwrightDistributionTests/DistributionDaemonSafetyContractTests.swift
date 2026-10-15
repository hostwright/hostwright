import XCTest
@testable import HostwrightDistribution

final class DistributionDaemonSafetyContractTests: XCTestCase {
    private let observationalHelp = """
    hostwrightd --foreground --config <hostwright.yaml>
    This phase observes, plans, and records daemon loop attempts only.
    It does not install a launch agent and does not perform unattended runtime mutation.
    """
    private let currentHelp = """
    hostwrightd --foreground --config <hostwright.yaml>
    hostwrightd --service --config <absolute-hostwright.yaml>
    Mutations require exact provider capability, ownership, plan confirmation, and durable fencing.
    """

    func testAcceptsBothExactObservationalReleaseIdentities() throws {
        for (version, commit) in [
            ("0.0.2-dev.11", "7d97d6c9ff878ec567c88e6993d4543ab8f0ad95"),
            ("0.0.2-dev.12", "71414005104933d8ee3591e8c91bc831bce2e2a2")
        ] {
            XCTAssertNoThrow(try DistributionDaemonSafetyContract.validate(
                observationalHelp, packageVersion: version, sourceCommit: commit
            ))
        }
    }

    func testRejectsObservationalHelpForCurrentOrUnknownSource() throws {
        for version in ["0.0.2-rc.11", "0.0.2-dev.11", "0.0.2-dev.12"] {
            XCTAssertThrowsError(try DistributionDaemonSafetyContract.validate(
                observationalHelp, packageVersion: version, sourceCommit: String(repeating: "a", count: 40)
            ))
        }
    }

    func testHistoricalContractRejectsMissingSafetyBoundaryOrServiceEntry() throws {
        for output in [
            "hostwrightd --foreground --config <hostwright.yaml>",
            observationalHelp + "\nhostwrightd --service --config <absolute-hostwright.yaml>"
        ] {
            XCTAssertThrowsError(try DistributionDaemonSafetyContract.validate(
                output, packageVersion: "0.0.2-dev.11",
                sourceCommit: "7d97d6c9ff878ec567c88e6993d4543ab8f0ad95"
            ))
        }
    }

    func testCurrentContractStillRequiresServiceAndMutationSafety() throws {
        XCTAssertNoThrow(try DistributionDaemonSafetyContract.validate(
            currentHelp, packageVersion: "0.0.2", sourceCommit: String(repeating: "a", count: 40)
        ))
        XCTAssertThrowsError(try DistributionDaemonSafetyContract.validate(
            currentHelp.replacingOccurrences(of: "durable fencing", with: "optional checks"),
            packageVersion: "0.0.2", sourceCommit: String(repeating: "a", count: 40)
        ))
    }
}
