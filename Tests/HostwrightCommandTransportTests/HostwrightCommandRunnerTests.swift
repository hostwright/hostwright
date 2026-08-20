import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
import HostwrightObservability

final class HostwrightCommandRunnerTests: XCTestCase {
    func testPersistentBootstrapAndStreamDispatchUseOnlyTheirInjectedClosures() {
        let log = CallLog()
        let persistentResult = CLIRunResult(standardOutput: "persistent\n", standardError: "persistent warning\n", exitCode: 17)
        let bootstrapResult = CLIRunResult(standardOutput: "bootstrap\n", standardError: "bootstrap warning\n", exitCode: 18)
        let streamResult = CLIRunResult(standardOutput: "stream\n", standardError: "stream warning\n", exitCode: 19)
        let environment = environment(log: log, persistentResult: persistentResult, bootstrapResult: bootstrapResult, streamResult: streamResult)

        XCTAssertEqual(HostwrightCommandRunner.run(arguments: ["capabilities"], environment: environment), persistentResult)
        XCTAssertEqual(HostwrightCommandRunner.run(arguments: ["daemon", "repair"], environment: environment), bootstrapResult)
        XCTAssertEqual(
            HostwrightCommandRunner.run(
                arguments: ["exec", "api", "--no-stdin", "--", "/bin/true"],
                environment: environment
            ),
            streamResult
        )

        XCTAssertEqual(log.persistentRequests.count, 1)
        XCTAssertEqual(log.bootstrapRequests.count, 1)
        XCTAssertEqual(log.streamRoutes.count, 1)
        XCTAssertEqual(log.persistentRequests[0].operation, "capabilities")
        XCTAssertEqual(log.bootstrapRequests[0].operation, "daemon")
        XCTAssertEqual(log.streamRoutes[0].transport, .persistentControlAPI)
        XCTAssertEqual(log.streamRoutes[0].execution, .stream(.exec))
        XCTAssertEqual(log.persistentSocketPaths, ["/tmp/hostwright.sock"])
        XCTAssertEqual(log.streamSocketPaths, ["/tmp/hostwright.sock"])
        XCTAssertEqual(log.streamRequestIDs, ["request-1"])
        XCTAssertNil(log.persistentRequests[0].idempotencyKey)
        XCTAssertEqual(log.bootstrapRequests[0].idempotencyKey, "request-1")
        guard case .object(let persistentBody)? = log.persistentRequests[0].body else {
            return XCTFail("Expected a typed persistent CLI request body.")
        }
        XCTAssertEqual(persistentBody["workingDirectory"], .string("/client/project"))
    }

    func testTransportFailuresMapSafelyAndNeverFallBackToDirectExecution() {
        let log = CallLog()
        let environment = HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright.sock" },
            persistentSend: { _, _ in
                log.recordPersistentFailure()
                throw TransportFailure.unavailable
            },
            bootstrapSend: { _ in
                log.recordBootstrapCall()
                return completedResponse(requestID: "unexpected", result: CLIRunResult())
            },
            streamRun: { _, _, _ in
                log.recordStreamCall()
                return CLIRunResult()
            },
            requestID: { "request-1" }
        )

        let result = HostwrightCommandRunner.run(arguments: ["capabilities"], environment: environment)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("HW-API-002"))
        XCTAssertEqual(log.persistentFailures, 1)
        XCTAssertEqual(log.bootstrapCalls, 0)
        XCTAssertEqual(log.streamCalls, 0)
    }

    func testFailureReasonCodesMapToCliDiagnosticCategories() {
        let cases: [(ControlReasonCode, String)] = [
            (.invalidRequest, "HW-API-001"),
            (.unauthorized, "HW-SECURITY-001"),
            (.conflict, "HW-CLI-003"),
            (.deadlineExceeded, "HW-API-002"),
            (.internalError, "HW-API-003"),
        ]

        for (reason, expectedCode) in cases {
            let environment = HostwrightCommandTransportEnvironment(
                socketPath: { "/tmp/hostwright.sock" },
                persistentSend: { _, request in
                    ControlResponseEnvelope(
                        requestID: request.requestID,
                        status: .rejected,
                        reasonCode: reason,
                        error: SanitizedError(code: "rejected", message: "safe rejection")
                    )
                },
                bootstrapSend: { _ in
                    completedResponse(requestID: "unexpected", result: CLIRunResult())
                },
                streamRun: { _, _, _ in CLIRunResult() },
                requestID: { "request-1" }
            )

            let result = HostwrightCommandRunner.run(arguments: ["capabilities"], environment: environment)
            XCTAssertNotEqual(result.exitCode, 0, "\(reason)")
            XCTAssertTrue(result.standardError.contains(expectedCode), "\(reason): \(result.standardError)")
        }
    }

    func testInvalidGeneratedRequestIDRejectsBeforeTransportDispatch() {
        let log = CallLog()
        let environment = environment(
            log: log,
            persistentResult: CLIRunResult(),
            bootstrapResult: CLIRunResult(),
            streamResult: CLIRunResult(),
            requestID: "invalid request id"
        )

        let result = HostwrightCommandRunner.run(arguments: ["capabilities", "--json"], environment: environment)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains("HW-API-003"))
        XCTAssertTrue(log.persistentRequests.isEmpty)
        XCTAssertTrue(log.bootstrapRequests.isEmpty)
        XCTAssertTrue(log.streamRoutes.isEmpty)
    }

    func testComposeScopeResolutionRejectsBeforePersistentTransportDispatch() {
        let log = CallLog()
        let cliEnvironment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "version: 3\nservices: {}\n" },
            writeTextFile: { _, _ in throw ParityError.unexpectedWrite },
            executablePath: { _ in nil },
            swiftVersion: { "Swift test" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS test" }
        )
        let environment = HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright.sock" },
            persistentSend: { socketPath, request in
                log.recordPersistent(socketPath: socketPath, request: request)
                return completedResponse(requestID: request.requestID, result: CLIRunResult())
            },
            bootstrapSend: { _ in throw ParityError.unexpectedRoute },
            streamRun: { _, _, _ in throw ParityError.unexpectedRoute },
            authorizationScope: { command, arguments in
                try CLIControlAuthorizationScopeResolver.resolve(
                    command: command,
                    arguments: arguments,
                    environment: cliEnvironment
                )
            },
            requestID: { "request-1" },
            workingDirectory: { "/client/project" }
        )

        let result = HostwrightCommandRunner.run(
            arguments: ["export-stack", "projectless.yaml", "--output", "json"],
            environment: environment
        )

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.contains(HostwrightErrorCode.controlAPIInvalid.rawValue))
        XCTAssertTrue(log.persistentRequests.isEmpty)
    }

    func testPersistentExecutorPreservesDirectResultsForSuccessDryRunAndConfirmationFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-command-parity-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestPath = root.appendingPathComponent("hostwright.yaml").path
        let desiredManifestPath = root.appendingPathComponent("desired.yaml").path
        let composePath = root.appendingPathComponent("compose.yaml").path
        let manifest = """
        version: 3
        project: parity
        services:
          api:
            image: ghcr.io/example/api:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let desiredManifest = manifest.replacingOccurrences(
            of: "ghcr.io/example/api:latest",
            with: "ghcr.io/example/api:next"
        )
        let compose = """
        name: parity
        services:
          api:
            image: ghcr.io/example/api:latest
            deploy:
              resources:
                reservations:
                  cpus: "1"
                  memory: 512m
                limits:
                  cpus: "2"
                  memory: 1g
        """
        try manifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)
        try desiredManifest.write(toFile: desiredManifestPath, atomically: true, encoding: .utf8)
        try compose.write(toFile: composePath, atomically: true, encoding: .utf8)
        let cliEnvironment = parityCLIEnvironment(root: root)
        let transportEnvironment = HostwrightCommandTransportEnvironment(
            socketPath: { "/private/tmp/hostwright-parity.sock" },
            persistentSend: { _, request in
                guard let response = try CLIControlCommandExecutor.execute(
                    request: request,
                    environment: cliEnvironment
                ) else { throw ParityError.unexpectedRoute }
                return response
            },
            bootstrapSend: { _ in throw ParityError.unexpectedRoute },
            streamRun: { _, _, _ in throw ParityError.unexpectedRoute },
            authorizationScope: { command, arguments in
                try CLIControlAuthorizationScopeResolver.resolve(
                    command: command,
                    arguments: arguments,
                    environment: cliEnvironment
                )
            },
            requestID: { "parity-request" },
            workingDirectory: { root.path }
        )
        let confirmation = String(repeating: "b", count: 64)
        let cases: [[String]] = [
            ["capabilities"],
            ["capabilities", "--json"],
            ["validate", manifestPath],
            ["plan", manifestPath, "--output", "json"],
            ["import-stack", composePath],
            ["import-stack", composePath, "--output", "json"],
            ["export-stack", manifestPath],
            ["export-stack", manifestPath, "--output", "json"],
            ["plan-stack-update", manifestPath, desiredManifestPath],
            [
                "plan-stack-update", manifestPath, desiredManifestPath,
                "--output", "json",
            ],
            ["image", "prune", "--dry-run"],
            ["volume", "prune", "--dry-run"],
            ["secret", "check", "keychain://hostwright.test/missing"],
            ["apply", manifestPath, "--confirm-plan", "not-a-digest"],
            ["state", "repair", "--confirm-repair", "not-a-digest"],
            ["metrics", "export", "--output-path", root.appendingPathComponent("metrics.json").path, "--confirm-snapshot", confirmation],
        ]

        for arguments in cases {
            let direct = HostwrightCLI.run(arguments: arguments, environment: cliEnvironment)
            let transported = HostwrightCommandRunner.run(
                arguments: arguments,
                environment: transportEnvironment
            )
            XCTAssertEqual(transported, direct, arguments.joined(separator: " "))
        }
    }

    private func environment(
        log: CallLog,
        persistentResult: CLIRunResult,
        bootstrapResult: CLIRunResult,
        streamResult: CLIRunResult,
        requestID: String = "request-1"
    ) -> HostwrightCommandTransportEnvironment {
        HostwrightCommandTransportEnvironment(
            socketPath: { "/tmp/hostwright.sock" },
            persistentSend: { socketPath, request in
                log.recordPersistent(socketPath: socketPath, request: request)
                return completedResponse(requestID: request.requestID, result: persistentResult)
            },
            bootstrapSend: { request in
                log.recordBootstrap(request: request)
                return completedResponse(requestID: request.requestID, result: bootstrapResult)
            },
            streamRun: { socketPath, route, requestID in
                log.recordStream(socketPath: socketPath, route: route, requestID: requestID)
                return streamResult
            },
            requestID: { requestID },
            workingDirectory: { "/client/project" }
        )
    }

    private func parityCLIEnvironment(root: URL) -> CLIEnvironment {
        let resolution = try! HostwrightLocalPathResolver.resolve(
            explicitStateDatabasePath: root.appendingPathComponent("state.sqlite").path,
            homeDirectory: root.path,
            environment: [:]
        )
        return CLIEnvironment(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readTextFile: { try String(contentsOfFile: $0, encoding: .utf8) },
            writeTextFile: { _, _ in throw ParityError.unexpectedWrite },
            executablePath: { _ in nil },
            localPathResolution: { _ in resolution },
            swiftVersion: { "Swift parity" },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "macOS parity" },
            observabilitySink: DisabledHostwrightLogSink(),
            observabilityCorrelationID: { "parity-correlation" }
        )
    }
}

private func completedResponse(requestID: String, result: CLIRunResult) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
        requestID: requestID,
        status: result.exitCode == 0 ? .completed : .error,
        reasonCode: result.exitCode == 0 ? .completed : .internalError,
        result: try! CLIControlResultContract.value(result),
        error: result.exitCode == 0 ? nil : SanitizedError(
            code: "cliExitNonZero",
            message: "The delegated CLI command returned a non-zero exit status."
        )
    )
}

private enum TransportFailure: Error {
    case unavailable
}

private enum ParityError: Error {
    case unexpectedRoute
    case unexpectedWrite
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var persistentRequests: [ControlRequestEnvelope] = []
    private(set) var bootstrapRequests: [ControlRequestEnvelope] = []
    private(set) var streamRoutes: [CLIControlRoute] = []
    private(set) var persistentSocketPaths: [String] = []
    private(set) var streamSocketPaths: [String] = []
    private(set) var streamRequestIDs: [String] = []
    private(set) var persistentFailures = 0
    private(set) var bootstrapCalls = 0
    private(set) var streamCalls = 0

    func recordPersistent(socketPath: String, request: ControlRequestEnvelope) {
        lock.lock()
        persistentRequests.append(request)
        persistentSocketPaths.append(socketPath)
        lock.unlock()
    }

    func recordBootstrap(request: ControlRequestEnvelope) {
        lock.lock()
        bootstrapRequests.append(request)
        lock.unlock()
    }

    func recordStream(socketPath: String, route: CLIControlRoute, requestID: String) {
        lock.lock()
        streamRoutes.append(route)
        streamSocketPaths.append(socketPath)
        streamRequestIDs.append(requestID)
        lock.unlock()
    }

    func recordPersistentFailure() {
        lock.lock()
        persistentFailures += 1
        lock.unlock()
    }

    func recordBootstrapCall() {
        lock.lock()
        bootstrapCalls += 1
        lock.unlock()
    }

    func recordStreamCall() {
        lock.lock()
        streamCalls += 1
        lock.unlock()
    }
}
