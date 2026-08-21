import Foundation
import XCTest
@testable import HostwrightCommandTransport
import HostwrightCLI
import HostwrightControlPlane
import HostwrightCore
import HostwrightManifest
import HostwrightObservability
import HostwrightRuntime

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
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
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
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
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
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
        """
        let swapped = """
        version: 3
        project: swapped-after-authorization
        services:
          api:
            image: ghcr.io/example/other:latest
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 1, memory: 512MiB}
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

    func testImportStackUnaryControlMapsCapacityWithoutWritesOrRuntime() throws {
        let compose = """
        name: gate09-import
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            deploy:
              resources:
                reservations:
                  cpus: "1"
                  memory: 512m
                limits:
                  cpus: "2"
                  memory: 1g
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
        XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(result.standardError, "")
        let output = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
        )
        XCTAssertEqual(output["kind"] as? String, "composeImport")
        XCTAssertEqual(output["schemaVersion"] as? Int, 1)
        XCTAssertEqual(output["contractVersion"] as? String, "v1")
        XCTAssertEqual(output["succeeded"] as? Bool, true)
        XCTAssertTrue((output["manifestText"] as? String)?.contains("memory: 512MiB") == true)
        let lossReport = try XCTUnwrap(output["lossReport"] as? [String: Any])
        XCTAssertEqual(lossReport["operation"] as? String, "import")
        XCTAssertEqual((lossReport["losses"] as? [[String: Any]])?.count, 0)
    }

    func testComposeExportAndUpdatePlanUnaryControlSnapshotEachInputOnce() throws {
        let current = """
        version: 3
        project: control-compose
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 2
                memory: 1GiB
        """
        let desired = current.replacingOccurrences(
            of: "ghcr.io/example/api:1",
            with: "ghcr.io/example/api:2"
        )
        let documents = [
            "/qualified/hostwright.yaml": current,
            "/qualified/current.yaml": current,
            "/qualified/desired.yaml": desired,
        ]
        let reads = LockedPathCounter()
        var environment = environment(
            logSink: LogCapture(),
            readTextFile: { path in
                reads.increment(path)
                return try XCTUnwrap(documents[path])
            }
        )
        environment.localPathResolution = { _ in
            XCTFail("Compose source-only control commands must not resolve state.")
            throw HostwrightDiagnostic(code: .stateStoreUnavailable, message: "unexpected state")
        }
        environment.runtimeAdapter = {
            XCTFail("Compose source-only control commands must not request runtime.")
            return RuntimeAdapterFactory.defaultLocal()
        }

        let exportRoute = try CLIControlRoute.classify(arguments: [
            "export-stack", "/qualified/hostwright.yaml", "--output", "json",
        ]).withAuthorizationScope(projectScope("control-compose"))
        let exportResponse = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: exportRoute),
            environment: environment
        ))
        let exportResult = try CLIControlResultContract.result(from: exportResponse)

        XCTAssertEqual(exportResponse.status, .completed)
        XCTAssertEqual(exportResult.exitCode, CLIExitCode.success.rawValue)
        XCTAssertTrue(exportResult.standardOutput.contains("\"kind\":\"composeExport\""))
        XCTAssertEqual(reads.value(for: "/qualified/hostwright.yaml"), 1)

        let updateRoute = try CLIControlRoute.classify(arguments: [
            "plan-stack-update", "/qualified/current.yaml", "/qualified/desired.yaml",
            "--output", "json",
        ]).withAuthorizationScope(projectScope("control-compose"))
        let updateResponse = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: updateRoute),
            environment: environment
        ))
        let updateResult = try CLIControlResultContract.result(from: updateResponse)

        XCTAssertEqual(updateResponse.status, .completed)
        XCTAssertEqual(updateResult.exitCode, CLIExitCode.success.rawValue)
        XCTAssertTrue(updateResult.standardOutput.contains("\"kind\":\"composeUpdatePlan\""))
        XCTAssertTrue(updateResult.standardOutput.contains("\"mutatesRuntime\":false"))
        XCTAssertEqual(reads.value(for: "/qualified/current.yaml"), 1)
        XCTAssertEqual(reads.value(for: "/qualified/desired.yaml"), 1)
    }

    func testRejectedComposeUpdateControlReturnsExactLossAndNoChanges() throws {
        let current = """
        version: 3
        project: control-compose
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let desired = """
        version: 3
        project: control-compose
        imagePolicy: require-digest
        services:
          api:
            image: ghcr.io/example/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let documents = ["/qualified/current.yaml": current, "/qualified/desired.yaml": desired]
        let reads = LockedPathCounter()
        let environment = environment(
            logSink: LogCapture(),
            readTextFile: { path in
                reads.increment(path)
                return try XCTUnwrap(documents[path])
            }
        )
        let route = try CLIControlRoute.classify(arguments: [
            "plan-stack-update", "/qualified/current.yaml", "/qualified/desired.yaml",
            "--output", "json",
        ]).withAuthorizationScope(projectScope("control-compose"))

        let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment
        ))
        let result = try CLIControlResultContract.result(from: response)

        XCTAssertEqual(response.status, .error)
        XCTAssertEqual(result.exitCode, CLIExitCode.validation.rawValue)
        XCTAssertEqual(result.standardOutput, "")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.standardError.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["accepted"] as? Bool, false)
        XCTAssertEqual((object["changes"] as? [[String: Any]])?.count, 0)
        let report = try XCTUnwrap(object["lossReport"] as? [String: Any])
        let losses = try XCTUnwrap(report["losses"] as? [[String: Any]])
        XCTAssertEqual(losses.map { $0["code"] as? String }, ["HW-COMPOSE-003"])
        XCTAssertEqual(losses.map { $0["path"] as? String }, ["$.desired.imagePolicy"])
        XCTAssertEqual(reads.value(for: "/qualified/current.yaml"), 1)
        XCTAssertEqual(reads.value(for: "/qualified/desired.yaml"), 1)
    }

    func testComposeControlRequiresExactManifestBackedProjectScope() throws {
        let manifest = """
        version: 3
        project: scoped-compose
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let documents = [
            "/qualified/manifest.yaml": manifest,
            "/qualified/current.yaml": manifest,
            "/qualified/desired.yaml": manifest,
        ]
        let cases: [[String]] = [
            ["export-stack", "/qualified/manifest.yaml", "--output", "json"],
            [
                "plan-stack-update", "/qualified/current.yaml", "/qualified/desired.yaml",
                "--output", "json",
            ],
        ]
        let expectedScope = projectScope("scoped-compose")
        let wrongScope = projectScope("other-compose")

        for arguments in cases {
            func environment(
                reads: LockedPathCounter,
                capture: LogCapture = LogCapture()
            ) -> CLIEnvironment {
                var value = self.environment(
                    logSink: capture,
                    readTextFile: { path in
                        reads.increment(path)
                        return try XCTUnwrap(documents[path])
                    }
                )
                value.localPathResolution = { _ in
                    XCTFail("Compose authorization must not resolve state.")
                    throw HostwrightDiagnostic(
                        code: .stateStoreUnavailable,
                        message: "unexpected state access"
                    )
                }
                value.runtimeAdapter = {
                    XCTFail("Compose authorization must not request runtime.")
                    return RuntimeAdapterFactory.defaultLocal()
                }
                return value
            }

            let unscoped = try CLIControlRoute.classify(arguments: arguments)
            let structurallyInvalidScopes = [
                unscoped.authorizationScope,
                CLIControlAuthorizationScope(
                    projectIdentifier: "not-a-resource-uuid",
                    resourceIdentifier: nil
                ),
                CLIControlAuthorizationScope(
                    projectIdentifier: expectedScope.projectIdentifier,
                    resourceIdentifier: HostwrightResourceUUID.legacy(
                        kind: "service",
                        identifier: "project-scoped-compose:api"
                    )
                ),
            ]
            for scope in structurallyInvalidScopes {
                let reads = LockedPathCounter()
                let capture = LogCapture()
                let route = unscoped.withAuthorizationScope(scope)
                XCTAssertThrowsError(try CLIControlCommandExecutor.prepare(
                    request: request(for: route),
                    environment: environment(reads: reads, capture: capture)
                )) { error in
                    XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
                }
                XCTAssertEqual(reads.total, 0)
                XCTAssertTrue(capture.records().isEmpty)
            }

            let wronglyScoped = unscoped.withAuthorizationScope(wrongScope)
            let wrongReads = LockedPathCounter()
            let wrongCapture = LogCapture()
            let wrongPrepared = try XCTUnwrap(CLIControlCommandExecutor.prepare(
                request: request(for: wronglyScoped),
                environment: environment(reads: wrongReads, capture: wrongCapture)
            ))
            XCTAssertEqual(wrongReads.total, 0)
            XCTAssertTrue(wrongCapture.records().isEmpty)
            XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
                prepared: wrongPrepared
            )) { error in
                XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
            }
            XCTAssertEqual(wrongReads.total, arguments[0] == "export-stack" ? 1 : 2)
            XCTAssertTrue(wrongCapture.records().isEmpty)

            let correctlyScoped = unscoped.withAuthorizationScope(expectedScope)
            let correctReads = LockedPathCounter()
            let correctCapture = LogCapture()
            let prepared = try XCTUnwrap(CLIControlCommandExecutor.prepare(
                request: request(for: correctlyScoped),
                environment: environment(reads: correctReads, capture: correctCapture)
            ))
            XCTAssertEqual(correctReads.total, 0)
            XCTAssertTrue(correctCapture.records().isEmpty)
            guard case .object(let fields)? = prepared.request.body else {
                return XCTFail("Expected a typed CLI request body.")
            }
            let expectedProjectID = try XCTUnwrap(expectedScope.projectIdentifier)
            XCTAssertEqual(
                fields["authorizationProjectID"],
                .string(expectedProjectID)
            )
            XCTAssertEqual(fields["authorizationResourceID"], .null)
            let response = try CLIControlCommandExecutor.execute(prepared: prepared)
            XCTAssertEqual(response.status, .completed)
            XCTAssertEqual(
                try CLIControlResultContract.result(from: response).exitCode,
                CLIExitCode.success.rawValue
            )
            XCTAssertEqual(correctReads.total, arguments[0] == "export-stack" ? 1 : 2)
        }
    }

    func testComposeUpdateAuthorizationRejectsMissingAmbiguousAndMismatchedProjectsBeforeExecution() throws {
        let valid = """
        version: 3
        project: current-project
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let missing = valid.replacingOccurrences(of: "project: current-project\n", with: "")
        let ambiguous = valid.replacingOccurrences(
            of: "project: current-project",
            with: "project: current-project\nproject: shadow-project"
        )
        let mismatched = valid.replacingOccurrences(
            of: "project: current-project",
            with: "project: desired-project"
        )
        let rejectedInputs = [
            (name: "missing-current", current: missing, desired: valid),
            (name: "missing-desired", current: valid, desired: missing),
            (name: "ambiguous-current", current: ambiguous, desired: valid),
            (name: "ambiguous-desired", current: valid, desired: ambiguous),
            (name: "mismatched", current: valid, desired: mismatched),
        ]
        for testCase in rejectedInputs {
            let capture = LogCapture()
            let reads = LockedPathCounter()
            let documents = [
                "/current.yaml": testCase.current,
                "/desired.yaml": testCase.desired,
            ]
            var environment = environment(
                logSink: capture,
                readTextFile: { path in
                    reads.increment(path)
                    return try XCTUnwrap(documents[path])
                }
            )
            environment.localPathResolution = { _ in
                XCTFail("Compose authorization must not resolve state.")
                throw HostwrightDiagnostic(
                    code: .stateStoreUnavailable,
                    message: "unexpected state access"
                )
            }
            environment.runtimeAdapter = {
                XCTFail("Compose authorization must not request runtime.")
                return RuntimeAdapterFactory.defaultLocal()
            }
            let route = try CLIControlRoute.classify(arguments: [
                "plan-stack-update", "/current.yaml", "/desired.yaml", "--output", "json",
            ]).withAuthorizationScope(projectScope("current-project"))
            XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
                request: request(for: route),
                environment: environment
            )) { error in
                XCTAssertEqual(
                    (error as? HostwrightDiagnostic)?.code,
                    .controlAPIInvalid,
                    testCase.name
                )
            }
            XCTAssertGreaterThan(reads.total, 0, testCase.name)
            XCTAssertTrue(capture.records().isEmpty, testCase.name)
        }
    }

    func testComposePersistentControlRejectsInvalidManifestAuthorityWithoutDelegatedCLI() throws {
        let valid = """
        version: 3
        project: current-project
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let invalidDocuments = [
            "malformed": "version: [",
            "oversized": String(repeating: "x", count: ManifestParser.maximumUTF8Bytes + 1),
            "duplicate-key": "version: 3\nproject: first\nproject: second\nservices: {}\n",
        ]
        for (name, invalid) in invalidDocuments {
            for arguments in [
                ["export-stack", "/manifest.yaml", "--output", "json"],
                [
                    "plan-stack-update", "/current.yaml", "/desired.yaml",
                    "--output", "json",
                ],
            ] {
                let documents = [
                    "/manifest.yaml": invalid,
                    "/current.yaml": invalid,
                    "/desired.yaml": valid,
                ]
                let capture = LogCapture()
                let reads = LockedPathCounter()
                let route = try CLIControlRoute.classify(arguments: arguments)
                    .withAuthorizationScope(projectScope("current-project"))
                XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
                    request: request(for: route),
                    environment: environment(
                        logSink: capture,
                        readTextFile: { path in
                            reads.increment(path)
                            return try XCTUnwrap(documents[path])
                        }
                    )
                )) { error in
                    XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid, name)
                }
                XCTAssertGreaterThan(reads.total, 0, name)
                XCTAssertTrue(capture.records().isEmpty, name)
            }
        }

        let projectless = valid.replacingOccurrences(
            of: "project: current-project\n",
            with: ""
        )
        let capture = LogCapture()
        let route = try CLIControlRoute.classify(arguments: [
            "export-stack", "/manifest.yaml", "--output", "json",
        ]).withAuthorizationScope(projectScope("current-project"))
        XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
            request: request(for: route),
            environment: environment(
                logSink: capture,
                readTextFile: { _ in projectless }
            )
        )) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
        }
        XCTAssertTrue(capture.records().isEmpty)

        let unreadableCapture = LogCapture()
        let unreadableRoute = try CLIControlRoute.classify(arguments: [
            "export-stack", "/unreadable.yaml", "--output", "json",
        ]).withAuthorizationScope(projectScope("current-project"))
        XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
            request: request(for: unreadableRoute),
            environment: environment(
                logSink: unreadableCapture,
                readTextFile: { _ in throw POSIXError(.EACCES) }
            )
        )) { error in
            XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
        }
        XCTAssertTrue(unreadableCapture.records().isEmpty)
    }

    func testComposeControlUsesBoundedSnapshotReaderAndRetainsExactBoundaryAndFailures() throws {
        let suffix = "\n" + """
        version: 3
        project: bounded-control
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests:
                cpus: 1
                memory: 512MiB
              limits:
                cpus: 1
                memory: 512MiB
        """
        let documents: [String: Result<String, ManifestParseError>] = [
            "/exact.yaml": .success(
                String(
                    repeating: "#",
                    count: ManifestParser.maximumUTF8Bytes - suffix.utf8.count
                ) + suffix
            ),
            "/oversized.yaml": .success(
                String(repeating: "x", count: ManifestParser.maximumUTF8Bytes + 1)
            ),
            "/invalid.yaml": .failure(.failed([
                ManifestIssue(
                    code: .manifestParseFailed,
                    message: "Manifest must be valid UTF-8 text.",
                    path: "$"
                ),
            ])),
        ]
        let boundedReads = LockedPathCounter()
        let capture = LogCapture()
        var environment = environment(
            logSink: capture,
            readTextFile: { _ in
                XCTFail("Compose control commands must not invoke the unbounded reader.")
                throw NSError(domain: "unexpected-unbounded-read", code: 1)
            }
        )
        environment.readBoundedTextFile = { path, maximumBytes in
            boundedReads.increment(path)
            if path == "/unsafe.yaml" {
                throw POSIXError(.ELOOP)
            }
            let text = try XCTUnwrap(documents[path]).get()
            guard text.utf8.count <= maximumBytes else {
                return String(repeating: "x", count: maximumBytes + 1)
            }
            return text
        }

        for testCase in [
            (path: "/exact.yaml", scope: projectScope("bounded-control"), success: true),
            (
                path: "/oversized.yaml",
                scope: projectScope("bounded-control"),
                success: false
            ),
            (
                path: "/invalid.yaml",
                scope: projectScope("bounded-control"),
                success: false
            ),
            (
                path: "/unsafe.yaml",
                scope: projectScope("bounded-control"),
                success: false
            ),
        ] {
            let route = try CLIControlRoute.classify(arguments: [
                "export-stack", testCase.path, "--output", "json",
            ]).withAuthorizationScope(testCase.scope)
            let logsBefore = capture.records().count
            if testCase.success {
                let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
                    request: request(for: route),
                    environment: environment
                ))
                let result = try CLIControlResultContract.result(from: response)
                XCTAssertEqual(response.status, .completed)
                XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
                let envelope = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: Data(result.standardOutput.utf8)
                    ) as? [String: Any]
                )
                XCTAssertEqual(envelope["kind"] as? String, "composeExport")
                XCTAssertEqual(envelope["succeeded"] as? Bool, true)
            } else {
                XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
                    request: request(for: route),
                    environment: environment
                )) { error in
                    XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
                }
                XCTAssertEqual(capture.records().count, logsBefore)
            }
            XCTAssertEqual(boundedReads.value(for: testCase.path), 1)
        }

        for testCase in [
            (path: "/exact.yaml", success: true),
            (path: "/oversized.yaml", success: false),
            (path: "/invalid.yaml", success: false),
            (path: "/unsafe.yaml", success: false),
        ] {
            let readsBefore = boundedReads.value(for: testCase.path)
            let route = try CLIControlRoute.classify(arguments: [
                "plan-stack-update", "/exact.yaml", testCase.path, "--output", "json",
            ]).withAuthorizationScope(projectScope("bounded-control"))
            let logsBefore = capture.records().count
            if testCase.success {
                let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
                    request: request(for: route),
                    environment: environment
                ))
                let result = try CLIControlResultContract.result(from: response)
                XCTAssertEqual(response.status, .completed)
                XCTAssertEqual(result.exitCode, CLIExitCode.success.rawValue)
                let envelope = try XCTUnwrap(
                    try JSONSerialization.jsonObject(
                        with: Data(result.standardOutput.utf8)
                    ) as? [String: Any]
                )
                XCTAssertEqual(envelope["kind"] as? String, "composeUpdatePlan")
                XCTAssertEqual(envelope["accepted"] as? Bool, true)
            } else {
                XCTAssertThrowsError(try CLIControlCommandExecutor.execute(
                    request: request(for: route),
                    environment: environment
                )) { error in
                    XCTAssertEqual((error as? HostwrightDiagnostic)?.code, .controlAPIInvalid)
                }
                XCTAssertEqual(capture.records().count, logsBefore)
            }
            XCTAssertEqual(boundedReads.value(for: testCase.path), readsBefore + 1)
        }
    }

    func testComposeUpdateControlReadsSameAndDotAliasIdentityOnce() throws {
        let authorized = """
        version: 3
        project: alias-compose
        services:
          api:
            image: ghcr.io/example/api:1
            resources:
              requests: {cpus: 1, memory: 512MiB}
              limits: {cpus: 2, memory: 1GiB}
        """
        let swapped = authorized.replacingOccurrences(
            of: "project: alias-compose",
            with: "project: swapped-after-first-read"
        )
        for paths in [
            ["manifest.yaml", "manifest.yaml"],
            ["manifest.yaml", "./manifest.yaml"],
        ] {
            let reads = LockedCounter()
            let environment = environment(
                logSink: LogCapture(),
                readTextFile: { path in
                    XCTAssertEqual(path, "/client/project/manifest.yaml")
                    reads.increment()
                    return reads.value == 1 ? authorized : swapped
                }
            )
            let route = try CLIControlRoute.classify(arguments: [
                "plan-stack-update", paths[0], paths[1], "--output", "json",
            ]).withWorkingDirectory("/client/project")
                .withAuthorizationScope(projectScope("alias-compose"))

            let response = try XCTUnwrap(CLIControlCommandExecutor.execute(
                request: request(for: route),
                environment: environment
            ))
            let result = try CLIControlResultContract.result(from: response)

            let caseDescription = paths.joined(separator: ", ")
            XCTAssertEqual(response.status, .completed, caseDescription)
            XCTAssertEqual(reads.value, 1, caseDescription)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(result.standardOutput.utf8)
                ) as? [String: Any]
            )
            XCTAssertEqual(object["currentPath"] as? String, "manifest.yaml")
            XCTAssertEqual(object["desiredPath"] as? String, "manifest.yaml")
            XCTAssertEqual((object["changes"] as? [[String: Any]])?.count, 0)
        }
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

    private func projectScope(_ project: String) -> CLIControlAuthorizationScope {
        CLIControlAuthorizationScope(
            projectIdentifier: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: "project-\(project)"
            ),
            resourceIdentifier: nil
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

private final class LockedPathCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Int] = [:]

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.reduce(0, +)
    }

    func value(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage[path, default: 0]
    }

    func increment(_ path: String) {
        lock.lock()
        storage[path, default: 0] += 1
        lock.unlock()
    }
}
