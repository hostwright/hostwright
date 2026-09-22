import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightRuntime

extension HostwrightRuntimeTests {

    func testSecureRuntimeProcessRunnerDrainsLargeStdout() async throws {
        let runner = SecureRuntimeProcessRunner()
        let result = try await runner.run(processSpec(
            executablePath: "/usr/bin/jot",
            arguments: ["-b", "x", "70000"]
        ))

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertGreaterThan(result.standardOutput.utf8.count, 65_536)
    }

    func testSecureRuntimeProcessRunnerCapturesFailedCommandStderr() async {
        let runner = SecureRuntimeProcessRunner()
        do {
            _ = try await runner.run(processSpec(
                executablePath: "/usr/bin/swiftc",
                arguments: ["--hostwright-invalid-option"]
            ))
            XCTFail("Expected command failure.")
        } catch let error as RuntimeAdapterError {
            guard case .commandFailed(let status, _, let standardError) = error else {
                return XCTFail("Expected commandFailed, got \(error).")
            }
            XCTAssertNotEqual(status, 0)
            XCTAssertFalse(standardError.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testSecureRuntimeProcessRunnerReturnsAppleStatusExitOneForTypedParsing() async throws {
        let spec = RuntimeCommandSpec(
            executablePath: "/usr/bin/false",
            arguments: ["system", "status", "--format", "json"],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            exitStatusPolicy: .appleContainerSystemStatus,
            purpose: "exercise the Apple system-status exit contract"
        )

        let result = try await SecureRuntimeProcessRunner().run(spec)

        XCTAssertEqual(result.exitStatus, 1)
    }

    func testSecureRuntimeProcessRunnerObservesRepeatedRapidProcessTermination() async throws {
        let runner = SecureRuntimeProcessRunner()
        for sequence in 0..<25 {
            let result = try await runner.run(processSpec(
                executablePath: "/usr/bin/printf",
                arguments: ["%s", String(sequence)]
            ))
            XCTAssertEqual(result.exitStatus, 0)
            XCTAssertEqual(result.standardOutput, String(sequence))
        }
    }

    func testSecureRuntimeProcessRunnerRejectsShellExecutables() async {
        let runner = SecureRuntimeProcessRunner()
        do {
            _ = try await runner.run(processSpec(
                executablePath: "/bin/sh",
                arguments: ["-c", "exit 0"]
            ))
            XCTFail("Expected secure executable rejection.")
        } catch let error as RuntimeAdapterError {
            guard case .permissionDenied(let message) = error else {
                return XCTFail("Expected permissionDenied, got \(error).")
            }
            XCTAssertTrue(message.contains("secure identity"))
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

    func testSecureRuntimeProcessRunnerCarriesSensitiveValuesOutsideArgvAndRedactsOutput() async throws {
        let opaqueSecret = "opaque-runtime-environment-value"
        let spec = RuntimeCommandSpec(
            executablePath: "/usr/bin/printenv",
            arguments: ["SESSION"],
            environment: ["SESSION": opaqueSecret],
            sensitiveValues: [opaqueSecret],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Verify bounded sensitive environment transport."
        )

        XCTAssertFalse(spec.arguments.joined(separator: " ").contains(opaqueSecret))
        let result = try await SecureRuntimeProcessRunner().run(spec)

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.standardOutput.contains(opaqueSecret))
        XCTAssertTrue(result.standardOutput.contains("[REDACTED]"))
        XCTAssertFalse(result.spec.environment.values.contains(opaqueSecret))
    }

    func testSecureRuntimeProcessRunnerRedactsBoundedStandardInput() async throws {
        let secret = "opaque-runtime-standard-input"
        let spec = RuntimeCommandSpec(
            executablePath: "/bin/cat",
            arguments: [],
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Verify bounded standard-input transport."
        )

        let result = try await SecureRuntimeProcessRunner().run(
            spec,
            standardInput: Data((secret + "\n").utf8)
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.standardOutput.contains(secret))
        XCTAssertEqual(result.standardOutput, "[REDACTED]")
        XCTAssertTrue(result.spec.sensitiveValues.isEmpty)
    }

    func testSecureRuntimeProcessRunnerReportsTimeoutAndCancellationSeparately() async {
        let runner = SecureRuntimeProcessRunner()

        do {
            _ = try await runner.run(processSpec(
                executablePath: "/bin/sleep",
                arguments: ["30"],
                timeout: 1
            ))
            XCTFail("Expected timeout.")
        } catch let error as RuntimeAdapterError {
            guard case .commandTimedOut(_, let partialOutput, _) = error else {
                return XCTFail("Expected commandTimedOut, got \(error).")
            }
            XCTAssertTrue(partialOutput.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error).")
        }

        let cancellationSpec = processSpec(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeout: 10
        )
        let task = Task { try await runner.run(cancellationSpec) }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch let error as RuntimeAdapterError {
            guard case .commandCancelled = error else {
                return XCTFail("Expected commandCancelled, got \(error).")
            }
        } catch {
            XCTFail("Unexpected error: \(error).")
        }
    }

}
