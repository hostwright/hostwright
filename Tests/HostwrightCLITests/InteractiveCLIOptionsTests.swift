import HostwrightCLI
import Testing

@Suite
struct InteractiveCLIOptionsTests {
    @Test
    func parsesExecWithoutShellInterpretation() throws {
        let command = try CLICommand.parse(arguments: [
            "exec", "api", "--manifest", "/tmp/hostwright.yaml",
            "--runtime-provider", "apple-cli", "--tty", "--",
            "/bin/printf", "%s", "$(not-executed)"
        ])
        guard case .interactive(let options) = command else {
            Issue.record("Expected an interactive command.")
            return
        }
        #expect(options.command == .exec)
        #expect(options.serviceName == "api")
        #expect(options.arguments == ["/bin/printf", "%s", "$(not-executed)"])
        #expect(options.terminal)
    }

    @Test
    func parsesCopyWithExactlyOneContainerEndpoint() throws {
        let command = try CLICommand.parse(arguments: [
            "copy", "/tmp/input.bin", "api:/work/input.bin", "--output", "json"
        ])
        guard case .interactive(let options) = command else {
            Issue.record("Expected an interactive command.")
            return
        }
        #expect(options.command == .copy)
        #expect(options.source == "/tmp/input.bin")
        #expect(options.destination == "api:/work/input.bin")
        #expect(options.output == .json)
    }

    @Test
    func attachTTYSelectionIsExactAndDefaultsToEnabled() throws {
        let defaultCommand = try CLICommand.parse(arguments: [
            "attach", "api"
        ])
        guard case .interactive(let defaultOptions) = defaultCommand else {
            Issue.record("Expected an attach command.")
            return
        }
        #expect(defaultOptions.terminal)
        #expect(defaultOptions.forwardsStandardInput)

        let disabledCommand = try CLICommand.parse(arguments: [
            "attach", "api", "--no-tty", "--no-stdin"
        ])
        guard case .interactive(let disabledOptions) = disabledCommand else {
            Issue.record("Expected an attach command.")
            return
        }
        #expect(!disabledOptions.terminal)
        #expect(!disabledOptions.forwardsStandardInput)
    }

    @Test
    func parsesLogsFollowIntoTheExactNoninteractiveStreamOperation() throws {
        let command = try CLICommand.parse(arguments: [
            "logs", "api", "/tmp/hostwright.yaml",
            "--follow", "--tail", "25",
            "--state-db", "/tmp/state.sqlite",
            "--runtime-provider", "apple-cli",
            "--timeout", "45",
            "--output", "json"
        ])
        guard case .interactive(let options) = command else {
            Issue.record("Expected a streaming logs command.")
            return
        }
        #expect(options.command == .logsFollow)
        #expect(options.serviceName == "api")
        #expect(options.manifestPath == "/tmp/hostwright.yaml")
        #expect(options.stateDatabasePath == "/tmp/state.sqlite")
        #expect(options.runtimeProvider == .appleCLI)
        #expect(options.timeoutSeconds == 45)
        #expect(options.output == .json)
        #expect(options.tail == 25)
        #expect(!options.terminal)
        #expect(!options.forwardsStandardInput)
    }

    @Test
    func rejectsFollowOnlyOptionsWithoutFollow() {
        #expect(throws: CLIUsageError.self) {
            try CLICommand.parse(arguments: [
                "logs", "api", "--runtime-provider", "apple-cli"
            ])
        }
    }

    @Test(arguments: [
        ["exec", "api", "--"],
        ["exec", "api", "--tty", "--json", "--", "true"],
        ["attach", "api", "--json"],
        ["copy", "/tmp/a", "/tmp/b"],
        ["copy", "api:/a", "worker:/b"],
        ["copy", "../host", "api:/a"],
        ["copy", "/tmp/a", "api:/../escape"],
        ["export", "api", "../relative"],
        ["stats", "../unsafe"]
    ])
    func rejectsUnsafeOrAmbiguousStreamingArguments(arguments: [String]) {
        #expect(throws: CLIUsageError.self) {
            try CLICommand.parse(arguments: arguments)
        }
    }
}
