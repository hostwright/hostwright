import XCTest

@testable import HostwrightCLI

final class SchedulerCLICommandTests: XCTestCase {
    func testSchedulerActionsRequireOneStrictRequestSource() throws {
        for action in SchedulerCLIAction.allCases {
            let command = try CLICommand.parse(arguments: [
                "scheduler", action.rawValue, "--request", "scheduler.json", "--json",
            ])
            guard case .scheduler(let options) = command else {
                return XCTFail("Expected a scheduler command for \(action.rawValue).")
            }
            XCTAssertEqual(options.action, action)
            XCTAssertEqual(options.requestSource, .file(path: "scheduler.json"))
            XCTAssertEqual(options.output, .json)
        }

        guard case .scheduler(let stdinOptions) = try CLICommand.parse(arguments: [
            "scheduler", "simulate", "--stdin", "--output", "text",
        ]) else {
            return XCTFail("Expected a scheduler stdin command.")
        }
        XCTAssertEqual(stdinOptions.requestSource, .standardInput)
        XCTAssertEqual(stdinOptions.output, .text)
    }

    func testSchedulerParserRejectsMissingOrAmbiguousInputAndOutput() {
        let invalidArguments: [[String]] = [
            ["scheduler", "plan"],
            ["scheduler", "plan", "--stdin", "--request", "request.json"],
            ["scheduler", "plan", "--request", "request.json", "--stdin"],
            ["scheduler", "plan", "--request", "request.json", "--json", "--output", "text"],
            ["scheduler", "plan", "--request", "-"],
            ["scheduler", "plan", "--request", "request.json", "--unknown"],
        ]

        for arguments in invalidArguments {
            XCTAssertThrowsError(
                try CLICommand.parse(arguments: arguments),
                arguments.joined(separator: " ")
            )
        }
    }

    func testDirectCLIExecutionFailsClosedWithoutAControlTransport() throws {
        let text = HostwrightCLI.run(arguments: [
            "scheduler", "status", "--stdin",
        ])
        XCTAssertNotEqual(text.exitCode, 0)
        XCTAssertTrue(text.standardError.contains("persistent Control API"))

        let json = HostwrightCLI.run(arguments: [
            "scheduler", "apply", "--stdin", "--json",
        ])
        XCTAssertNotEqual(json.exitCode, 0)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(json.standardError.utf8)))
    }
}
