import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
import HostwrightObservability

final class CLIControlCommandExecutorTests: XCTestCase {
    func testUnarySuccessPreservesExactTypedCLIResult() throws {
        let capture = LogCapture()
        let environment = environment(logSink: capture)
        let route = try CLIControlRoute.classify(arguments: ["capabilities", "--json"])
        let request = request(for: route)

        let response = try XCTUnwrap(
            CLIControlCommandExecutor.execute(request: request, environment: environment)
        )
        XCTAssertEqual(capture.records().count, 2)
        let expected = HostwrightCLI.run(arguments: route.arguments, environment: environment)

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.reasonCode, .completed)
        XCTAssertNil(response.error)
        XCTAssertEqual(try CLIControlResultContract.result(from: response), expected)
        XCTAssertEqual(capture.records().count, 4)
    }

    func testUnaryNonzeroPreservesTypedResultAndErrorEnvelope() throws {
        let capture = LogCapture()
        let environment = environment(logSink: capture)
        let route = try CLIControlRoute.classify(arguments: [
            "secret", "check", "keychain://gate09/unit",
        ])
        let request = request(for: route)

        let response = try XCTUnwrap(
            CLIControlCommandExecutor.execute(request: request, environment: environment)
        )
        XCTAssertEqual(capture.records().count, 2)
        let expected = HostwrightCLI.run(arguments: route.arguments, environment: environment)

        XCTAssertNotEqual(expected.exitCode, 0)
        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(response.reasonCode, .internalError)
        XCTAssertEqual(response.error?.code, "cliExitNonZero")
        XCTAssertEqual(
            response.error?.message,
            "The delegated CLI command returned a non-zero exit status."
        )
        XCTAssertEqual(try CLIControlResultContract.result(from: response), expected)
        XCTAssertEqual(capture.records().count, 4)
    }

    func testDeclaredAuthorizationScopeMismatchRejectsBeforeCLIExecution() throws {
        let capture = LogCapture()
        let manifest = """
        version: 3
        project: executor-scope
        services:
          api:
            image: ghcr.io/example/api:latest
        """
        let environment = environment(
            logSink: capture,
            readTextFile: { path in
                XCTAssertEqual(path, "/qualified/hostwright.yaml")
                return manifest
            }
        )
        let route = try CLIControlRoute.classify(arguments: ["plan", "/qualified/hostwright.yaml"])
            .withAuthorizationScope(
                CLIControlAuthorizationScope(
                    projectIdentifier: "project-other",
                    resourceIdentifier: nil
                )
            )

        XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment
        )) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
        }
        XCTAssertTrue(capture.records().isEmpty)
    }

    func testRelativeManifestIsResolvedAgainstAuthenticatedClientContext() throws {
        let capture = LogCapture()
        let manifest = """
        version: 3
        project: relative-context
        services:
          api:
            image: ghcr.io/example/api:latest
        """
        let environment = environment(
            logSink: capture,
            readTextFile: { path in
                XCTAssertEqual(path, "/client/project/hostwright.yaml")
                return manifest
            }
        )
        let route = try CLIControlRoute.classify(arguments: [
            "plan", "hostwright.yaml", "--output", "json",
        ]).withWorkingDirectory("/client/project")
            .withAuthorizationScope(
                CLIControlAuthorizationScope(
                    projectIdentifier: HostwrightResourceUUID.legacy(
                        kind: "project", identifier: "project-relative-context"),
                    resourceIdentifier: nil
                )
            )

        let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment
        ))

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.reasonCode, .completed)
        XCTAssertEqual(try CLIControlResultContract.result(from: response).exitCode, 0)
    }

    func testPreparedCommandExecutesTheExactAuthorizedManifestSnapshot() throws {
        let authorized = """
        version: 3
        project: authorized-snapshot
        services:
          api:
            image: ghcr.io/example/api:latest
        """
        let swapped = """
        version: 3
        project: swapped-after-authorization
        services:
          api:
            image: ghcr.io/example/other:latest
        """
        let reads = LockedCounter()
        let environment = environment(
            logSink: LogCapture(),
            readTextFile: { _ in
                reads.increment()
                return reads.value == 1 ? authorized : swapped
            }
        )
        let route = try CLIControlRoute.classify(arguments: [
            "plan", "/qualified/hostwright.yaml", "--output", "json",
        ]).withAuthorizationScope(CLIControlAuthorizationScope(
            projectIdentifier: HostwrightResourceUUID.legacy(
                kind: "project", identifier: "project-authorized-snapshot"),
            resourceIdentifier: nil
        ))

        let prepared = try XCTUnwrap(CLIControlCommandExecutor.prepare(
            request: request(for: route), environment: environment))
        let response = try CLIControlCommandExecutor.execute(prepared: prepared)
        let result = try CLIControlResultContract.result(from: response)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(reads.value, 1)
        XCTAssertTrue(result.standardOutput.contains("authorized-snapshot"))
        XCTAssertFalse(result.standardOutput.contains("swapped-after-authorization"))
    }

    func testImportStackSnapshotsComposeInputWithoutTreatingItAsAHostwrightManifest() throws {
        let compose = """
        name: gate09-import
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        """
        let reads = LockedCounter()
        let environment = environment(
            logSink: LogCapture(),
            readTextFile: { path in
                XCTAssertEqual(path, "/qualified/compose.yaml")
                reads.increment()
                return compose
            }
        )
        let route = try CLIControlRoute.classify(arguments: [
            "import-stack", "/qualified/compose.yaml", "--output", "json",
        ])

        let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment
        ))
        let result = try CLIControlResultContract.result(from: response)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(reads.value, 1)
        XCTAssertTrue(result.standardOutput.contains("\"manifest\""))
    }

    func testStreamRouteIsRejectedForUnaryExecutor() throws {
        let route = try CLIControlRoute.classify(arguments: [
            "exec", "api", "--no-stdin", "--", "/bin/true",
        ])
        let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment(logSink: LogCapture())
        ))

        XCTAssertEqual(response.status, .rejected)
        XCTAssertEqual(response.reasonCode, .unsupportedOperation)
        XCTAssertEqual(response.error?.code, "streamRequired")
        XCTAssertNil(response.result)
    }

    func testUnrelatedRequestReturnsNil() throws {
        let request = ControlRequestEnvelope(
            requestID: "executor-unrelated",
            operation: "unrelated",
            timeoutMilliseconds: 1_000,
            body: .object(["value": .string("unrelated")])
        )

        XCTAssertNil(try CLIControlCommandExecutor.execute(
            request: request,
            environment: environment(logSink: LogCapture())
        ))
    }

    private func request(for route: CLIControlRoute) -> ControlRequestEnvelope {
        ControlRequestEnvelope(
            requestID: "executor-request",
            operation: route.operation,
            timeoutMilliseconds: 1_000,
            idempotencyKey: route.mutating ? "executor-idempotency" : nil,
            body: route.requestBody()
        )
    }

    private func environment(
        logSink: any HostwrightLogSinking,
        readTextFile: @escaping (String) throws -> String = { path in
            throw NSError(
                domain: "CLIControlCommandExecutorTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected read: \(path)"]
            )
        }
    ) -> CLIEnvironment {
        CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: readTextFile,
            writeTextFile: { _, _ in
                XCTFail("The unary executor test environment must not write local files.")
            },
            executablePath: { _ in nil },
            swiftVersion: { "Swift test" },
            platformSnapshot: { PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64") },
            operatingSystemDescription: { "macOS test" },
            observabilitySink: logSink,
            observabilityCorrelationID: { "executor-correlation" }
        )
    }
}

private final class LogCapture: HostwrightLogSinking, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostwrightLogRecord] = []

    func emit(_ record: HostwrightLogRecord) -> HostwrightLogEmission {
        lock.lock()
        values.append(record)
        lock.unlock()
        return HostwrightLogEmission(status: .emitted)
    }

    func records() -> [HostwrightLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
