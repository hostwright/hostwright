import HostwrightCLI
import HostwrightRuntime
import Testing

@Suite
struct LifecycleCLIOptionsTests {
    @Test
    func parsesCompleteDryRunContractDeterministically() throws {
        let command = try CLICommand.parse(arguments: [
            "up",
            "/tmp/hostwright.yaml",
            "--service", "web",
            "--service", "api",
            "--state-db", "/tmp/state.sqlite",
            "--dry-run",
            "--runtime-provider", "apple-cli",
            "--timeout", "45",
            "--parallelism", "8",
            "--output", "json"
        ])

        guard case .lifecycle(let options) = command else {
            Issue.record("Expected a lifecycle command.")
            return
        }
        #expect(options.command == .up)
        #expect(options.manifestPath == "/tmp/hostwright.yaml")
        #expect(options.serviceNames == ["api", "web"])
        #expect(options.stateDatabasePath == "/tmp/state.sqlite")
        #expect(options.dryRun)
        #expect(options.confirmationPlanSHA256 == nil)
        #expect(options.runtimeProvider == .appleCLI)
        #expect(options.timeoutSeconds == 45)
        #expect(options.parallelism == 8)
        #expect(options.output == .json)
    }

    @Test
    func parsesExactConfirmationAndRunTarget() throws {
        let digest = String(repeating: "a", count: 64)
        let command = try CLICommand.parse(arguments: [
            "run", "--service", "job", "--confirm-plan", digest
        ])

        guard case .lifecycle(let options) = command else {
            Issue.record("Expected a lifecycle command.")
            return
        }
        #expect(options.command == .run)
        #expect(options.serviceNames == ["job"])
        #expect(options.confirmationPlanSHA256 == digest)
        #expect(!options.dryRun)
    }

    @Test(arguments: [
        ["up"],
        ["up", "--dry-run", "--confirm-plan", String(repeating: "a", count: 64)],
        ["up", "--confirm-plan", "not-a-digest"],
        ["up", "--dry-run", "--parallelism", "0"],
        ["up", "--dry-run", "--parallelism", "33"],
        ["up", "--dry-run", "--timeout", "0"],
        ["run", "--dry-run"],
        ["run", "--service", "../unsafe", "--dry-run"],
        ["run", "--service", "job", "--service", "job", "--dry-run"]
    ])
    func rejectsAmbiguousOrUnsafeMutationArguments(arguments: [String]) {
        #expect(throws: CLIUsageError.self) {
            try CLICommand.parse(arguments: arguments)
        }
    }
}
