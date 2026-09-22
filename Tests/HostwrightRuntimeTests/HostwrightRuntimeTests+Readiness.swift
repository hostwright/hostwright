import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {
    func testAppleContainerSystemStatusUsesExactReadOnlyJSONCommand() {
        let spec = AppleContainerCommand.spec(
            kind: .systemStatus,
            executable: ResolvedRuntimeExecutable(
                name: "container",
                path: "/usr/local/bin/container"
            ),
            timeout: RuntimeCommandTimeout(seconds: 15)
        )

        XCTAssertEqual(spec.arguments, ["system", "status", "--format", "json"])
        XCTAssertEqual(spec.classification, .readOnly)
        XCTAssertEqual(spec.exitStatusPolicy, .appleContainerSystemStatus)
        XCTAssertEqual(spec.timeout.seconds, 15)
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateReadOnlyExecution(spec))
    }

    func testAppleContainerSystemStatusExitPolicyIsExactAndReadOnly() {
        let unrelated = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["list"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateReadOnlyExecution(unrelated))

        let mutating = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["system", "status", "--format", "json"],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .startManagedService,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "fixture"
        )
        XCTAssertThrowsError(try RuntimeCommandPolicy.validateSupportedMutation(mutating))
    }

    func testAppleContainerSystemStatusParserIsBoundedAndStrictAboutReadiness() throws {
        let running = try AppleContainerSystemStatusParser.parse(
            #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
            cliVersion: "container CLI version 1.1.0\n"
        )
        XCTAssertEqual(running.serviceState, .running)
        XCTAssertEqual(running.cliVersion, "1.1.0")
        XCTAssertEqual(running.serviceVersion, "1.1.0")
        XCTAssertEqual(running.serviceBuild, "release")

        let stopped = try AppleContainerSystemStatusParser.parse(
            #"{"status":"not running","apiServerVersion":"","apiServerBuild":""}"#,
            cliVersion: "container CLI version 1.1.0"
        )
        XCTAssertEqual(stopped.serviceState, .notRunning)
        XCTAssertNil(stopped.serviceVersion)

        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"starting","apiServerVersion":"","apiServerBuild":""}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                String(repeating: "x", count: AppleContainerSystemStatusParser.maximumBytes + 1),
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","status":"not running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release\nforged"}"#,
                cliVersion: "container CLI version 1.1.0"
            )
        )
        XCTAssertThrowsError(
            try AppleContainerSystemStatusParser.parse(
                #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0","apiServerBuild":"release"}"#,
                cliVersion: String(repeating: "x", count: 1_025) + " version 1.1.0"
            )
        )
    }

    func testAppleContainerReadinessRunsVersionAndServiceProbesThroughRuntimeBoundary() async throws {
        let executable = "/usr/local/bin/container"
        let runner = RoutingRuntimeProcessRunner { spec in
            let output: String
            let exitStatus: Int32
            switch spec.arguments {
            case ["--version"]:
                output = "container CLI version 1.1.0\n"
                exitStatus = 0
            case ["system", "status", "--format", "json"]:
                output = #"{"status":"not running","apiServerVersion":"","apiServerBuild":""}"#
                exitStatus = 1
            default:
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "unexpected readiness command"
                )
            }
            return RuntimeCommandResult(
                spec: spec,
                exitStatus: exitStatus,
                standardOutput: output,
                standardError: ""
            )
        }
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [AppleContainerCommand.executableName: executable]
            ),
            processRunner: runner
        )

        let readiness = try await adapter.runtimeReadiness()

        XCTAssertEqual(readiness.serviceState, .notRunning)
        XCTAssertEqual(
            runner.calls.map(\.arguments),
            [["system", "status", "--format", "json"]]
        )
        XCTAssertTrue(runner.calls.allSatisfy { $0.classification == .readOnly })
    }
}
