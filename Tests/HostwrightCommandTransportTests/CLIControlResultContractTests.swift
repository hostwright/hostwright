import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore

final class CLIControlResultContractTests: XCTestCase {
    func testRoundTripPreservesStandardOutputStandardErrorAndExitCode() throws {
        let expected = CLIRunResult(
            standardOutput: "structured output\n",
            standardError: "warning on stderr\n",
            exitCode: 42
        )
        let response = ControlResponseEnvelope(
            requestID: "result-1",
            status: .error,
            reasonCode: .internalError,
            result: try CLIControlResultContract.value(expected),
            error: SanitizedError(
                code: "cliExitNonZero",
                message: "The delegated CLI command returned a non-zero exit status."
            )
        )

        XCTAssertEqual(try CLIControlResultContract.result(from: response), expected)
    }

    func testRejectsInvalidEnvelopeSchemaExitRangeAndBoundedOutputOverflow() throws {
        let invalidSchema = ControlResponseEnvelope(
            requestID: "result-2",
            status: .completed,
            reasonCode: .completed,
            result: .object([
                "exitCode": .integer(0),
                "resultSchemaVersion": .integer(2),
                "standardError": .string(""),
                "standardOutput": .string(""),
            ])
        )
        assertDiagnostic(.controlAPIExecutionFailed) {
            _ = try CLIControlResultContract.result(from: invalidSchema)
        }

        let invalidExit = ControlResponseEnvelope(
            requestID: "result-3",
            status: .completed,
            reasonCode: .completed,
            result: .object([
                "exitCode": .integer(Int64(Int32.max) + 1),
                "resultSchemaVersion": .integer(1),
                "standardError": .string(""),
                "standardOutput": .string(""),
            ])
        )
        assertDiagnostic(.controlAPIExecutionFailed) {
            _ = try CLIControlResultContract.result(from: invalidExit)
        }

        let oversized = CLIRunResult(
            standardOutput: String(repeating: "x", count: CLIControlResultContract.maximumCombinedOutputBytes),
            standardError: "x"
        )
        assertDiagnostic(.controlAPIExecutionFailed) {
            _ = try CLIControlResultContract.value(oversized)
        }

        let mismatchedStatus = ControlResponseEnvelope(
            requestID: "result-4",
            status: .completed,
            reasonCode: .completed,
            result: try CLIControlResultContract.value(CLIRunResult(exitCode: 7))
        )
        assertDiagnostic(.controlAPIExecutionFailed) {
            _ = try CLIControlResultContract.result(from: mismatchedStatus)
        }
    }

    private func assertDiagnostic(
        _ expectedCode: HostwrightErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, expectedCode, file: file, line: line)
        }
    }
}
