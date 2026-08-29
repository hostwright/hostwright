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
        if args.contains("rev-parse") && args.contains(
            "\(ReleaseQualificationLimits.phase08ReleaseCommit)^{commit}"
        ) {
            output = "\(ReleaseQualificationLimits.phase08ReleaseCommit)\n"
        } else if args.contains("rev-parse") {
            output = "1111111111111111111111111111111111111111\n"
        } else if args.contains("merge-base") {
            output = ""
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

private struct ReleaseQualificationStandardInputRecordingRunner:
    ReleaseQualificationStandardInputCommandRunning
{
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var inputs: [Data?] = []

        func record(_ input: Data?) {
            lock.lock()
            inputs.append(input)
            lock.unlock()
        }

        func snapshot() -> [Data?] {
            lock.lock()
            defer { lock.unlock() }
            return inputs
        }
    }

    let state: State

    func run(
        _ command: ReleaseQualificationCommandIdentity,
        standardInput: Data?,
        limits: ReleaseQualificationCommandLimits,
        cancellation: SecureSubprocessCancellation
    ) throws -> ReleaseQualificationCommandResult {
        state.record(standardInput)
        return ReleaseQualificationCommandResult(
            exitStatus: 0,
            standardOutput: Data(),
            standardError: Data(),
            durationMilliseconds: 1
        )
    }
}

final class ReleaseQualificationEnvironmentTests: XCTestCase {
    func testStandardInputRunnerConveniencePreservesNilAndExplicitBytes() throws {
        let state = ReleaseQualificationStandardInputRecordingRunner.State()
        let runner: any ReleaseQualificationStandardInputCommandRunning =
            ReleaseQualificationStandardInputRecordingRunner(state: state)
        let command = try ReleaseQualificationCommandIdentity(
            executablePath: "/usr/bin/true",
            arguments: [],
            workingDirectory: "/",
            purpose: "verify command runner standard-input capability"
        )
        let limits = try ReleaseQualificationCommandLimits()
        let payload = Data("exact immutable input\n".utf8)

        _ = try runner.run(
            command,
            limits: limits,
            cancellation: SecureSubprocessCancellation()
        )
        _ = try runner.run(
            command,
            standardInput: payload,
            limits: limits,
            cancellation: SecureSubprocessCancellation()
        )

        let inputs = state.snapshot()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertNil(inputs[0])
        XCTAssertEqual(inputs[1], payload)
    }

    func testQualificationSubprocessEnvironmentDisablesGitLazyFetch() {
        XCTAssertEqual(
            ReleaseQualificationSubprocessRunner.fixedEnvironment,
            [
                "GIT_NO_LAZY_FETCH": "1",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": SecureSubprocessEnvironment.trustedSystemPath,
            ]
        )
    }

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
        XCTAssertEqual(environment.phase08Release?.availability.status, .available)
        XCTAssertEqual(environment.phase08Release?.sourceContainsRelease, true)
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

    func testDetectorTreatsDiffAsDirtyEvenWhenStatusOutputIsEmpty() throws {
        struct DiffOnlyRunner: ReleaseQualificationCommandRunning {
            func run(
                _ command: ReleaseQualificationCommandIdentity,
                limits: ReleaseQualificationCommandLimits,
                cancellation: SecureSubprocessCancellation
            ) throws -> ReleaseQualificationCommandResult {
                let args = command.arguments
                let output: String
                if args.contains("rev-parse"), args.contains("HEAD^{commit}") {
                    output = "1111111111111111111111111111111111111111\n"
                } else if args.contains("status") || args.contains("ls-files") {
                    output = ""
                } else if args.contains("diff") {
                    output = "diff --git a/README.md b/README.md\n"
                } else {
                    throw ReleaseQualificationCommandError.failed
                }
                return ReleaseQualificationCommandResult(
                    exitStatus: 0,
                    standardOutput: Data(output.utf8),
                    standardError: Data(),
                    durationMilliseconds: 1
                )
            }
        }

        let detected = try ReleaseQualificationEnvironmentDetector(
            commandRunner: DiffOnlyRunner(),
            executableLocator: ReleaseQualificationFixtureLocator()
        ).detectSourceState(sourceRoot: ReleaseQualificationTestSupport.repositoryRoot())

        XCTAssertEqual(detected.source.availability.status, .available)
        XCTAssertEqual(detected.source.dirty, true)
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
