import Foundation
import XCTest
import HostwrightCore
@testable import HostwrightReleaseQualification

private struct ReleaseQualificationFixtureLocator:
    ReleaseQualificationExecutableLocating
{
    func path(for tool: ReleaseQualificationTool) -> String? {
        "/usr/bin/\(tool.rawValue)"
    }
}

private struct ReleaseQualificationFixtureRunner:
    ReleaseQualificationCommandRunning
{
    func run(
        _ command: ReleaseQualificationCommandIdentity,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        guard !cancellation.isCancelled else {
            throw ReleaseQualificationCommandError.cancelled
        }
        let args = command.arguments
        let output: String
        if args.contains("rev-parse") {
            output = "1111111111111111111111111111111111111111\n"
        } else if args.contains("status") {
            output = ""
        } else if args.contains("diff") || args.contains("ls-files") {
            output = ""
        } else if args == ["-productVersion"] {
            output = "26.0\n"
        } else if args == ["-buildVersion"] {
            output = "26A1\n"
        } else if args == ["-m"] {
            output = "arm64\n"
        } else if args == ["-n", "hw.model"] {
            output = "MacBookPro18,1\n"
        } else if args == ["-n", "hw.memsize"] {
            output = "17179869184\n"
        } else if args == ["-n", "hw.optional.arm64"] {
            output = "1\n"
        } else if args == ["--version"] || args == ["version"] ||
                    args == ["-version"] || args == ["-h"] ||
                    args == ["version", "--client=true", "--output=json"] {
            output = command.executablePath.contains("swift")
                ? "Apple Swift version 6.0.0\n"
                : "tool version 1.0.0\n"
        } else {
            throw ReleaseQualificationCommandError.failed
        }
        let data = Data(output.utf8)
        return ReleaseQualificationCommandResult(
            exitStatus: 0,
            standardOutput: data,
            standardError: Data(),
            durationMilliseconds: 1
        )
    }
}

final class ReleaseQualificationEnvironmentTests: XCTestCase {
    func testDetectorBindsCleanSourceHostToolsAndFrameworkFacts() throws {
        let root = ReleaseQualificationTestSupport.repositoryRoot()
        let environment = try ReleaseQualificationEnvironmentDetector(
            commandRunner: ReleaseQualificationFixtureRunner(),
            executableLocator: ReleaseQualificationFixtureLocator()
        ).detect(sourceRoot: root)
        try environment.validate()
        XCTAssertEqual(environment.source.commit, ReleaseQualificationTestSupport.commit)
        XCTAssertEqual(environment.source.dirty, false)
        XCTAssertEqual(environment.host.macOSVersion?.major, 26)
        XCTAssertEqual(environment.host.architecture, .arm64)
        XCTAssertEqual(
            environment.tool(.containerizationFramework)?.version,
            ReleaseQualificationSemanticVersion(major: 0, minor: 35, patch: 0)
        )
        XCTAssertGreaterThan(environment.commands.count, 0)
    }

    func testDetectorCancellationStopsBeforeAnyProviderWork() throws {
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try ReleaseQualificationEnvironmentDetector(
                commandRunner: ReleaseQualificationFixtureRunner(),
                executableLocator: ReleaseQualificationFixtureLocator()
            ).detect(
                sourceRoot: ReleaseQualificationTestSupport.repositoryRoot(),
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseQualificationCommandError, .cancelled)
        }
    }

    func testMalformedToolOutputProducesUnavailableFactsRatherThanClaims() throws {
        struct MalformedRunner: ReleaseQualificationCommandRunning {
            func run(
                _ command: ReleaseQualificationCommandIdentity,
                limits: ReleaseQualificationCommandLimits,
                cancellation: SecureSubprocessCancellation
            ) throws -> ReleaseQualificationCommandResult {
                let data = Data("not-a-version\n".utf8)
                return ReleaseQualificationCommandResult(
                    exitStatus: 0,
                    standardOutput: data,
                    standardError: Data(),
                    durationMilliseconds: 1
                )
            }
        }
        let environment = try ReleaseQualificationEnvironmentDetector(
            commandRunner: MalformedRunner(),
            executableLocator: ReleaseQualificationFixtureLocator()
        ).detect(sourceRoot: ReleaseQualificationTestSupport.repositoryRoot())
        XCTAssertEqual(environment.host.availability.status, .malformed)
        XCTAssertTrue(environment.tools.contains {
            $0.availability.status == .malformed ||
                $0.availability.status == .unavailable
        })
    }
}
