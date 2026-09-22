import Darwin
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightCore
@testable import HostwrightManifest
@testable import HostwrightRuntime

extension HostwrightCLITests {
    func testContentSHA256MatchesKnownVector() {
        XCTAssertEqual(
            hostwrightContentSHA256("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testCommandParserRecognizesSupportedCommands() throws {
        let recoveryGroupID = "11111111-1111-4111-8111-111111111111"
        let recoveryPlanSHA256 = String(repeating: "a", count: 64)
        let accepted: [(arguments: [String], expected: CLICommand)] = [
            (["--version"], .version),
            (["apply", "--confirm-plan", "abc123"],
             .apply(path: "hostwright.yaml", stateDatabasePath: nil, confirmedPlanHash: "abc123",
                    teamProfilePath: nil, approvalRecordPath: nil, runtimeProvider: .automatic)),
            (["init"], .initManifest),
            (
                ["import-stack", "compose.yaml"],
                .importStack(path: "compose.yaml", output: .text, teamProfilePath: nil)
            ),
            (
                ["import-stack", "compose.yaml", "--output", "json"],
                .importStack(path: "compose.yaml", output: .json, teamProfilePath: nil)
            ),
            (["export-stack", "hostwright.yaml"], .exportStack(path: "hostwright.yaml", output: .text)),
            (
                ["export-stack", "hostwright.yaml", "--output", "json"],
                .exportStack(path: "hostwright.yaml", output: .json)
            ),
            (
                ["plan-stack-update", "current.yaml", "desired.yaml", "--output", "json"],
                .planStackUpdate(currentPath: "current.yaml", desiredPath: "desired.yaml", output: .json)
            ),
            (["validate"], .validate(path: "hostwright.yaml", teamProfilePath: nil)),
            (["validate", "custom.yaml"], .validate(path: "custom.yaml", teamProfilePath: nil)),
            (["plan"], .plan(path: "hostwright.yaml", output: .text, teamProfilePath: nil)),
            (["plan", "--output", "json"], .plan(path: "hostwright.yaml", output: .json, teamProfilePath: nil)),
            (["paths"], .paths(stateDatabasePath: nil, output: .text)),
            (["paths", "--json"], .paths(stateDatabasePath: nil, output: .json)),
            (
                ["restart-budget", "status", "--project", "project-demo", "--json"],
                .restartBudget(
                    options: RestartBudgetCLIOptions(
                        action: .status(projectID: "project-demo"), stateDatabasePath: nil, output: .json))
            ),
            (
                [
                    "restart-budget", "release", "--project", "project-demo", "--service", "api", "--confirm-hold",
                    String(repeating: "a", count: 64), "--state-db", "/tmp/state.sqlite",
                ],
                .restartBudget(
                    options: RestartBudgetCLIOptions(
                        action: .release(
                            projectID: "project-demo", serviceName: "api", holdToken: String(repeating: "a", count: 64)),
                        stateDatabasePath: "/tmp/state.sqlite", output: .text))
            ),
            (
                ["status"],
                .status(path: "hostwright.yaml", stateDatabasePath: nil, output: .text, runtimeProvider: .automatic)
            ),
            (
                ["status", "--state-db", "/tmp/state.sqlite"],
                .status(
                    path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", output: .text,
                    runtimeProvider: .automatic)
            ),
            (
                ["status", "custom.yaml", "--state-db", "/tmp/state.sqlite", "--output", "json"],
                .status(
                    path: "custom.yaml", stateDatabasePath: "/tmp/state.sqlite", output: .json,
                    runtimeProvider: .automatic)
            ),
            (
                ["status", "--runtime-provider", "containerization"],
                .status(
                    path: "hostwright.yaml", stateDatabasePath: nil, output: .text, runtimeProvider: .containerization)
            ),
            (
                ["apply", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"],
                .apply(
                    path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123",
                    teamProfilePath: nil, approvalRecordPath: nil, runtimeProvider: .automatic)
            ),
            (
                ["apply", "custom.yaml", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123"],
                .apply(
                    path: "custom.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmedPlanHash: "abc123",
                    teamProfilePath: nil, approvalRecordPath: nil, runtimeProvider: .automatic)
            ),
            (
                ["apply", "--confirm-plan", "abc123", "--runtime-provider", "apple-cli"],
                .apply(
                    path: "hostwright.yaml", stateDatabasePath: nil, confirmedPlanHash: "abc123", teamProfilePath: nil,
                    approvalRecordPath: nil, runtimeProvider: .appleCLI)
            ),
            (
                ["logs", "api", "--tail", "25", "--state-db", "/tmp/state.sqlite"],
                .logs(serviceName: "api", path: "hostwright.yaml", tail: 25, stateDatabasePath: "/tmp/state.sqlite")
            ),
            (
                ["logs", "api", "--runtime-provider", "containerization"],
                .logs(
                    serviceName: "api", path: "hostwright.yaml", tail: 100, stateDatabasePath: nil,
                    runtimeProvider: .containerization)
            ),
            (
                [
                    "logs", "api", "/tmp/hostwright.yaml", "--follow", "--tail", "25", "--state-db",
                    "/tmp/state.sqlite", "--runtime-provider", "apple-cli", "--timeout", "45", "--output", "json",
                ],
                .interactive(
                    options: InteractiveCLIOptions(
                        command: .logsFollow, manifestPath: "/tmp/hostwright.yaml", serviceName: "api",
                        stateDatabasePath: "/tmp/state.sqlite", runtimeProvider: .appleCLI, timeoutSeconds: 45,
                        output: .json, terminal: false, forwardsStandardInput: false, tail: 25))
            ),
            (
                ["events", "--state-db", "/tmp/state.sqlite", "--project", "demo"],
                .events(
                    stateDatabasePath: "/tmp/state.sqlite", projectName: "demo", filters: EventFilters(),
                    stream: EventStreamCLIOptions(), output: .text)
            ),
            (
                ["events", "--state-db", "/tmp/state.sqlite", "--output", "json"],
                .events(
                    stateDatabasePath: "/tmp/state.sqlite", projectName: nil, filters: EventFilters(),
                    stream: EventStreamCLIOptions(), output: .json)
            ),
            (
                [
                    "events", "--state-db", "/tmp/state.sqlite", "--type", "cleanup.failed", "--service", "api",
                    "--severity", "error", "--limit", "5", "--sort", "desc", "--output", "json",
                ],
                .events(
                    stateDatabasePath: "/tmp/state.sqlite", projectName: nil,
                    filters: EventFilters(
                        type: "cleanup.failed", serviceName: "api", severity: .error, limit: 5, sort: .descending),
                    stream: EventStreamCLIOptions(), output: .json)
            ),
            (
                ["recovery", "--state-db", "/tmp/state.sqlite", "--project", "demo", "--output", "json"],
                .recovery(action: .inspect, stateDatabasePath: "/tmp/state.sqlite", projectName: "demo", output: .json)
            ),
            (
                [
                    "recovery", "resume", "--group", recoveryGroupID, "--confirm-plan", recoveryPlanSHA256, "--timeout",
                    "45", "--state-db", "/tmp/state.sqlite", "--output", "json",
                ],
                .recovery(
                    action: .resume(
                        groupID: recoveryGroupID, confirmationPlanSHA256: recoveryPlanSHA256, timeoutSeconds: 45),
                    stateDatabasePath: "/tmp/state.sqlite", projectName: nil, output: .json)
            ),
            (
                ["recovery", "rollback", "--group", recoveryGroupID, "--confirm-plan", recoveryPlanSHA256],
                .recovery(
                    action: .rollback(
                        groupID: recoveryGroupID, confirmationPlanSHA256: recoveryPlanSHA256, timeoutSeconds: 120),
                    stateDatabasePath: nil, projectName: nil, output: .text)
            ),
            (
                ["cleanup", "--state-db", "/tmp/state.sqlite", "--dry-run"],
                .cleanup(
                    path: "hostwright.yaml", stateDatabasePath: "/tmp/state.sqlite", confirmation: .dryRun,
                    teamProfilePath: nil, approvalRecordPath: nil)
            ),
            (
                [
                    "diagnostics", "--state-db", "/tmp/state.sqlite", "--bundle", "/tmp/diagnostics.json", "--project",
                    "demo", "--manifest", "custom.yaml",
                ],
                .diagnostics(
                    stateDatabasePath: "/tmp/state.sqlite", bundlePath: "/tmp/diagnostics.json", projectName: "demo",
                    manifestPath: "custom.yaml")
            ),
            (["doctor"], .doctor(stateDatabasePath: nil, output: .text)),
            (["doctor", "--output", "json"], .doctor(stateDatabasePath: nil, output: .json)),
            (
                ["doctor", "--state-db", "/tmp/state.sqlite", "--json"],
                .doctor(stateDatabasePath: "/tmp/state.sqlite", output: .json)
            ),
            (
                [
                    "extension", "check", "--declaration", "/tmp/extension.json", "--executable", "/tmp/extension",
                    "--output", "json",
                ],
                .extensionCheck(declarationPath: "/tmp/extension.json", executablePath: "/tmp/extension", output: .json)
            ),
        ]
        for testCase in accepted {
            XCTAssertEqual(
                try CLICommand.parse(arguments: testCase.arguments), testCase.expected,
                "Accepted arguments: \(testCase.arguments)"
            )
        }

        let rejected: [[String]] = [
            ["apply", "--state-db", "/tmp/state.sqlite"],
            ["apply", "--state-db", "/tmp/state.sqlite", "--confirm-plan", "abc123", "--force"],
            ["restart-budget", "release", "--project", "project-demo", "--service", "api", "--confirm-hold", "wrong"],
            ["paths", "--json", "--output", "text"],
            ["paths", "--output", "text", "--json"],
            ["paths", "--output", "text", "--output", "json"],
            ["paths", "--state-db", "/tmp/a.sqlite", "--state-db", "/tmp/b.sqlite"],
            ["doctor", "--output", "yaml"],
            ["doctor", "--json", "--output", "text"],
            ["doctor", "--state-db"],
            ["import-stack"],
            ["import-stack", "compose.yaml", "--write"],
            ["export-stack"],
            ["export-stack", "a.yaml", "b.yaml"],
            ["export-stack", "a.yaml", "--write"],
            ["plan-stack-update", "current.yaml"],
            ["plan-stack-update", "current.yaml", "desired.yaml", "extra.yaml"],
            ["plan-stack-update", "current.yaml", "desired.yaml", "--write"],
            ["events", "--state-db", "/tmp/state.sqlite", "--sort", "newest"],
            ["recovery", "resume"],
            ["recovery", "resume", "--group", "not-a-uuid", "--confirm-plan", String(repeating: "a", count: 64)],
            [
                "recovery", "rollback", "--group", "11111111-1111-4111-8111-111111111111", "--confirm-plan",
                "not-a-digest",
            ],
            ["recovery", "--timeout", "30"],
            ["diagnostics", "--state-db", "/tmp/state.sqlite"],
            ["status", "--runtime-provider", "other"],
            ["status", "--runtime-provider", "auto", "--runtime-provider", "apple-cli"],
            ["apply", "--confirm-plan", "abc123", "--runtime-provider", "other"],
            ["extension"],
            ["extension", "run"],
            ["extension", "check", "--declaration", "relative.json", "--executable", "/tmp/extension"],
            [
                "extension", "check", "--declaration", "/tmp/extension.json", "--executable", "/tmp/extension",
                "--output", "yaml",
            ],
        ]
        for arguments in rejected {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments), "Rejected arguments: \(arguments)"
            )
        }
    }

    func testVersionOutput() {
        let result = HostwrightCLI.run(arguments: ["--version"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "\(HostwrightIdentity.version)\n")
        XCTAssertEqual(result.standardError, "")
    }

    func testHelpDocumentsOutputModesAndExamples() {
        let result = HostwrightCLI.run(arguments: ["--help"], environment: environment(files: FileBox()))
        let usageFailure = HostwrightCLI.run(arguments: ["unknown"], environment: environment(files: FileBox()))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(usageFailure.exitCode, CLIExitCode.commandUsage.rawValue)
        XCTAssertTrue(result.standardOutput.contains("hostwright plan [path] [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright import-stack <path> [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright export-stack <manifest> [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright plan-stack-update <current> <desired> [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright status [path] [--state-db <path>] [--output text|json]"))
        for command in ["up", "down", "run", "start", "stop", "restart", "rm", "update"] {
            XCTAssertTrue(
                result.standardOutput.contains("hostwright \(command) [path]"),
                "Missing lifecycle command \(command) from help."
            )
        }
        for command in ["exec", "attach", "copy", "export", "inspect", "stats", "logs"] {
            for usage in [result.standardOutput, usageFailure.standardError] {
                XCTAssertTrue(
                    usage.contains("hostwright \(command) "),
                    "Missing interactive command \(command) from usage."
                )
            }
        }
        XCTAssertTrue(
            result.standardOutput.contains(
                "Every lifecycle command supports --json or --output json."
            )
        )
        XCTAssertTrue(result.standardOutput.contains("hostwright recovery [--state-db <path>] [--project <name>] [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright recovery resume --group <uuid> --confirm-plan <hash>"))
        XCTAssertTrue(result.standardOutput.contains("hostwright recovery rollback --group <uuid> --confirm-plan <hash>"))
        XCTAssertTrue(result.standardOutput.contains("hostwright diagnostics [--state-db <path>] --bundle <path>"))
        XCTAssertTrue(result.standardOutput.contains("hostwright extension check --declaration <absolute-path> --executable <absolute-path> [--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright capabilities [--json|--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright paths [--state-db <path>] [--json|--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("hostwright migrate preview <path> [--json|--output text|json]"))
        XCTAssertTrue(result.standardOutput.contains("JSON output is supported for capabilities, paths, migrate preview"))
        XCTAssertTrue(result.standardOutput.contains("import-stack reads a narrow safe stack-file subset"))
        XCTAssertTrue(result.standardOutput.contains("Neither command writes files, resolves state, or observes or mutates runtime."))
        XCTAssertTrue(result.standardOutput.contains("Diagnostics-v1 remains a local redacted JSON export."))
        XCTAssertTrue(result.standardOutput.contains("hostwright import-stack compose.yaml --output json"))
        XCTAssertTrue(result.standardOutput.contains("hostwright export-stack hostwright.yaml --output json"))
        XCTAssertTrue(result.standardOutput.contains("hostwright plan-stack-update current.yaml desired.yaml --output json"))
        XCTAssertTrue(result.standardOutput.contains("hostwright doctor --output json"))
        XCTAssertTrue(result.standardOutput.contains("--team-profile <path>"))
        XCTAssertTrue(result.standardOutput.contains("--approval-record <path>"))
        XCTAssertTrue(result.standardOutput.contains("Team profiles and approvals are loaded only from explicit local paths."))
        XCTAssertTrue(result.standardOutput.contains("it is not sandboxed"))
    }

    func testJSONErrorsUseStableExitCodesAndEnvelope() throws {
        let usage = HostwrightCLI.run(arguments: ["unknown", "--output", "json"], environment: environment(files: FileBox()))

        XCTAssertEqual(usage.exitCode, CLIExitCode.commandUsage.rawValue)
        let usageJSON = try jsonObject(usage.standardError)
        XCTAssertEqual(usageJSON["kind"] as? String, "error")
        XCTAssertEqual(usageJSON["code"] as? String, HostwrightErrorCode.commandUsage.rawValue)
        XCTAssertEqual(usageJSON["exitCode"] as? Int, Int(CLIExitCode.commandUsage.rawValue))

        let invalidManifest = HostwrightCLI.run(
            arguments: ["plan", "--output", "json"],
            environment: environment(files: FileBox(files: [HostwrightIdentity.manifestFileName: "version: 3\nproject: demo\nservices: {}\n"]))
        )

        XCTAssertEqual(invalidManifest.exitCode, CLIExitCode.validation.rawValue)
        let manifestJSON = try jsonObject(invalidManifest.standardError)
        XCTAssertEqual(manifestJSON["kind"] as? String, "error")
        let issues = try XCTUnwrap(manifestJSON["issues"] as? [[String: Any]])
        XCTAssertTrue(issues.contains { $0["code"] as? String == HostwrightErrorCode.manifestValidationFailed.rawValue })
    }
}
