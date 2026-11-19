import Foundation
import XCTest
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
@testable import HostwrightCommandTransport

final class CLIUnaryInputRoutingTests: XCTestCase {
    func testRestoreFailureAfterResponseReturnsResponseAndWarnsOnce() throws {
        let response = ControlResponseEnvelope(requestID: "unary-input-test", status: .completed, reasonCode: .completed)
        var warnings: [String] = []
        var restores = 0
        let actual = try CLIUnarySecretInput.sendRestoringInput(restore: {
            restores += 1
            throw InputFailure.restore
        }, warn: { warnings.append($0) }) { response }

        XCTAssertEqual(actual, response)
        XCTAssertEqual(restores, 1)
        XCTAssertEqual(warnings, ["Warning: terminal settings could not be restored. Run `stty sane`.\n"])
    }

    func testRestoreFailureAfterRequestErrorPreservesOriginalError() {
        var restores = 0
        XCTAssertThrowsError(try CLIUnarySecretInput.sendRestoringInput(restore: {
            restores += 1
            throw InputFailure.restore
        }, warn: { _ in XCTFail("Unexpected restore warning after request failure") }) {
            throw InputFailure.request
        }) {
            XCTAssertEqual($0 as? InputFailure, .request)
        }
        XCTAssertEqual(restores, 1)
    }

    func testOnlyInputCommandsUseDescriptorTransportWithUnchangedRequestShape() throws {
        let calls = InputCalls()
        let environment = makeEnvironment(
            persistentSend: { _, request in
                calls.record(request, input: false)
                return completedInputResponse(request)
            },
            persistentInputSend: { _, request in
                calls.record(request, input: true)
                return completedInputResponse(request)
            }
        )
        let inputCommands = [
            ["secret", "create", "keychain://hostwright.test/token"],
            ["secret", "update", "keychain://hostwright.test/token", "--output", "json"],
            ["registry", "login", "registry.example.test", "--username", "test-user"],
        ]
        let metadataCommands = [
            ["secret", "list"],
            ["secret", "check", "keychain://hostwright.test/token"],
            ["secret", "delete", "keychain://hostwright.test/token"],
            ["registry", "logout", "registry.example.test"],
            ["capabilities", "--json"],
        ]
        for command in inputCommands + metadataCommands {
            XCTAssertEqual(HostwrightCommandRunner.run(arguments: command, environment: environment).exitCode, 0, command.joined(separator: " "))
        }
        XCTAssertEqual(calls.input.count, inputCommands.count)
        XCTAssertEqual(calls.metadata.count, metadataCommands.count)
        for request in calls.input {
            XCTAssertNotNil(try CLIControlRoute.validate(request: request))
            guard case .object(let body)? = request.body else {
                return XCTFail("Expected the existing CLI request body")
            }
            XCTAssertNil(body["stdin"])
            XCTAssertNil(body["secret"])
            XCTAssertNil(body["inputDescriptor"])
        }
    }

    func testUnavailableInputTransportNeverFallsBackToMutationOrLocalInput() {
        let calls = InputCalls()
        let environment = makeEnvironment(persistentSend: { _, request in
            calls.record(request, input: false)
            return completedInputResponse(request)
        })
        let result = HostwrightCommandRunner.run(
            arguments: ["secret", "create", "keychain://hostwright.test/token"],
            environment: environment
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("HW-API-002"))
        XCTAssertTrue(calls.metadata.isEmpty)
    }

    func testDeniedInputResponsePreservesAuthorizationFailure() {
        let environment = makeEnvironment(
            persistentSend: { _, _ in throw InputFailure.unexpected },
            persistentInputSend: { _, request in
                ControlResponseEnvelope(
                    requestID: request.requestID,
                    status: .rejected,
                    reasonCode: .unauthorized,
                    error: SanitizedError(code: "denied", message: "Input is not authorized.")
                )
            }
        )
        let result = HostwrightCommandRunner.run(
            arguments: ["secret", "update", "keychain://hostwright.test/token"],
            environment: environment
        )
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("HW-SECURITY-001"))
    }

    func testInputCapabilityUsesExistingReportShape() throws {
        let report = HostwrightCapabilityCatalog.report
        let input = try XCTUnwrap(report.capabilities.first { $0.identifier == HostwrightUnaryInputCapability.identifier })
        XCTAssertEqual(input.state, .stable)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(HostwrightCapabilityReport.self, from: data)
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(report.schemaVersion, 1)
    }

    private func makeEnvironment(
        persistentSend: @escaping HostwrightCommandTransportEnvironment.PersistentSend,
        persistentInputSend: HostwrightCommandTransportEnvironment.PersistentInputSend? = nil
    ) -> HostwrightCommandTransportEnvironment {
        var environment = HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright-test.sock" },
            persistentSend: persistentSend,
            bootstrapSend: { _ in throw InputFailure.unexpected },
            streamRun: { _, _, _ in throw InputFailure.unexpected },
            requestID: { "unary-input-test" },
            workingDirectory: { "/test/project" },
            readStandardInput: { _ in throw InputFailure.unexpected }
        )
        if let persistentInputSend { environment.persistentInputSend = persistentInputSend }
        return environment
    }

}

private func completedInputResponse(_ request: ControlRequestEnvelope) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
        requestID: request.requestID,
        status: .completed,
        reasonCode: .completed,
        result: .object([
            "resultSchemaVersion": .integer(1),
            "standardOutput": .string(""),
            "standardError": .string(""),
            "exitCode": .integer(0),
        ])
    )
}

private enum InputFailure: Error { case unexpected, request, restore }

private final class InputCalls: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var input: [ControlRequestEnvelope] = []
    private(set) var metadata: [ControlRequestEnvelope] = []
    func record(_ request: ControlRequestEnvelope, input: Bool) {
        lock.lock(); defer { lock.unlock() }
        if input { self.input.append(request) } else { metadata.append(request) }
    }
}
