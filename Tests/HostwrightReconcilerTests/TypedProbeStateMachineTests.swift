import Foundation
import XCTest
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime

final class TypedProbeStateMachineTests: XCTestCase {
    func testManifestProbeMappingPreservesEveryTypedField() {
        let mapped = RuntimeProbeManifestMapper.map(
            HostwrightProbes(
                startup: HostwrightProbe(
                    action: .exec(["/bin/startup", "--quiet"]),
                    startPeriod: 4,
                    interval: 5,
                    timeout: 6,
                    successThreshold: 2,
                    failureThreshold: 7
                ),
                readiness: HostwrightProbe(action: .http(port: 8080, path: "/ready")),
                liveness: HostwrightProbe(action: .tcp(port: 8081))
            )
        )

        XCTAssertEqual(
            mapped.startup,
            RuntimeProbeConfiguration(
                action: .exec(
                    RuntimeProbeExecAction(command: ["/bin/startup", "--quiet"])
                ),
                startPeriodSeconds: 4,
                intervalSeconds: 5,
                timeoutSeconds: 6,
                successThreshold: 2,
                failureThreshold: 7
            )
        )
        XCTAssertEqual(
            mapped.readiness?.action,
            .http(RuntimeProbeHTTPAction(port: 8080, path: "/ready"))
        )
        XCTAssertEqual(
            mapped.liveness?.action,
            .tcp(RuntimeProbeTCPAction(port: 8081))
        )
    }

    func testValidatorRequiresDeclaredLoopbackPort() throws {
        let probe = RuntimeProbeConfiguration(
            action: .http(RuntimeProbeHTTPAction(port: 8080, path: "/health"))
        )

        XCTAssertThrowsError(
            try RuntimeProbeValidator.validate(
                RuntimeProbeSet(readiness: probe),
                declaredContainerPorts: [8081],
                capabilities: .allAvailable()
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .undeclaredPort(8080))
        }

        try RuntimeProbeValidator.validate(
            RuntimeProbeSet(readiness: probe),
            declaredContainerPorts: [8080],
            capabilities: .allAvailable()
        )
        XCTAssertEqual(
            RuntimeProbeHTTPAction(port: 8080, path: "/health").implicitLoopbackURL?.absoluteString,
            "http://127.0.0.1:8080/health"
        )
    }

    func testValidatorReportsUnavailableProbeActionBeforeExecution() {
        let capabilities = RuntimeProbeCapabilities(
            actions: [
                RuntimeProbeActionCapability(
                    action: .exec,
                    state: .available,
                    reason: .implemented
                ),
                RuntimeProbeActionCapability(
                    action: .http,
                    state: .unavailable,
                    reason: .notImplemented
                ),
                RuntimeProbeActionCapability(
                    action: .tcp,
                    state: .blocked,
                    reason: .policyBlocked
                )
            ]
        )

        XCTAssertThrowsError(
            try RuntimeProbeValidator.validate(
                RuntimeProbeSet(
                    readiness: RuntimeProbeConfiguration(
                        action: .http(RuntimeProbeHTTPAction(port: 8080))
                    )
                ),
                declaredContainerPorts: [8080],
                capabilities: capabilities
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProbeValidationError,
                .capabilityUnavailable(
                    action: .http,
                    state: .unavailable,
                    reason: .notImplemented
                )
            )
        }
    }

    func testValidatorRejectsUnboundedAndAmbiguousProbeInputs() {
        XCTAssertThrowsError(
            try RuntimeProbeValidator.validate(
                RuntimeProbeSet(
                    startup: RuntimeProbeConfiguration(
                        action: .exec(RuntimeProbeExecAction(command: []))
                    )
                ),
                declaredContainerPorts: [],
                capabilities: .allAvailable()
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .emptyExecCommand)
        }

        XCTAssertThrowsError(
            try RuntimeProbeValidator.validate(
                RuntimeProbeSet(
                    readiness: RuntimeProbeConfiguration(
                        action: .http(
                            RuntimeProbeHTTPAction(
                                port: 8080,
                                path: "http://example.test/health"
                            )
                        )
                    )
                ),
                declaredContainerPorts: [8080],
                capabilities: .allAvailable()
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .invalidHTTPPath)
        }
    }

    func testStartPeriodDefersStartupExecution() throws {
        let probes = RuntimeProbeSet(
            startup: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/check"])),
                startPeriodSeconds: 10
            )
        )
        let snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 1_000
        )

        XCTAssertEqual(
            try RuntimeProbeStateMachine.nextDirective(
                probes: probes,
                snapshot: snapshot,
                nowMilliseconds: 10_999
            ),
            .wait(untilMilliseconds: 11_000)
        )
        XCTAssertEqual(
            try RuntimeProbeStateMachine.nextDirective(
                probes: probes,
                snapshot: snapshot,
                nowMilliseconds: 11_000
            ),
            .execute(
                RuntimeProbeExecutionRequest(
                    resourceIdentifier: "service-1",
                    kind: .startup,
                    attempt: 1,
                    action: .exec(RuntimeProbeExecAction(command: ["/bin/check"])),
                    timeoutSeconds: 5
                )
            )
        )
    }

    func testStartupSuccessThresholdGatesReadinessAndLiveness() throws {
        let probes = RuntimeProbeSet(
            startup: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/startup"])),
                intervalSeconds: 1,
                successThreshold: 2
            ),
            readiness: RuntimeProbeConfiguration(
                action: .http(RuntimeProbeHTTPAction(port: 8080))
            ),
            liveness: RuntimeProbeConfiguration(
                action: .tcp(RuntimeProbeTCPAction(port: 8080))
            )
        )
        var snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )

        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .gated
        )
        XCTAssertEqual(
            RuntimeProbeStateMachine.liveness(probes: probes, snapshot: snapshot),
            .gated
        )
        XCTAssertThrowsError(
            try RuntimeProbeStateMachine.markAttemptStarted(
                kind: .readiness,
                probes: probes,
                snapshot: snapshot,
                nowMilliseconds: 0
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .invalidSnapshot)
        }

        var started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .startup,
            probes: probes,
            snapshot: snapshot,
            nowMilliseconds: 0
        )
        snapshot = try RuntimeProbeStateMachine.record(
            RuntimeProbeAttemptResult(outcome: .succeeded, completedAtMilliseconds: 5),
            request: started.request,
            probes: probes,
            snapshot: started.snapshot
        )
        XCTAssertEqual(snapshot.state(for: .startup)?.phase, .succeeding)
        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .gated
        )

        started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .startup,
            probes: probes,
            snapshot: snapshot,
            nowMilliseconds: 1_005
        )
        snapshot = try RuntimeProbeStateMachine.record(
            RuntimeProbeAttemptResult(outcome: .succeeded, completedAtMilliseconds: 1_010),
            request: started.request,
            probes: probes,
            snapshot: started.snapshot
        )

        XCTAssertEqual(snapshot.state(for: .startup)?.phase, .succeeded)
        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .notReady
        )
        XCTAssertEqual(
            RuntimeProbeStateMachine.liveness(probes: probes, snapshot: snapshot),
            .healthy
        )
        guard case .execute(let request) = try RuntimeProbeStateMachine.nextDirective(
            probes: probes,
            snapshot: snapshot,
            nowMilliseconds: 1_010
        ) else {
            return XCTFail("Expected readiness execution after startup succeeded.")
        }
        XCTAssertEqual(request.kind, .readiness)
    }

    func testReadinessThresholdPreservesLastStableOutcome() throws {
        let probes = RuntimeProbeSet(
            readiness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"])),
                intervalSeconds: 1,
                failureThreshold: 2
            )
        )
        var snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )
        snapshot = try apply(
            .succeeded,
            kind: .readiness,
            at: 0,
            probes: probes,
            snapshot: snapshot
        )
        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .ready
        )

        snapshot = try apply(
            .failed,
            kind: .readiness,
            at: 1_000,
            probes: probes,
            snapshot: snapshot
        )
        XCTAssertEqual(snapshot.state(for: .readiness)?.phase, .succeeded)
        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .ready
        )

        snapshot = try apply(
            .failed,
            kind: .readiness,
            at: 2_000,
            probes: probes,
            snapshot: snapshot
        )
        XCTAssertEqual(snapshot.state(for: .readiness)?.phase, .failed)
        XCTAssertEqual(
            RuntimeProbeStateMachine.readiness(probes: probes, snapshot: snapshot),
            .notReady
        )
    }

    func testLivenessFailureUsesExistingBoundedRestartPolicy() throws {
        let probes = RuntimeProbeSet(
            liveness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/live"])),
                failureThreshold: 1
            )
        )
        var snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )
        snapshot = try apply(
            .timedOut,
            kind: .liveness,
            at: 0,
            probes: probes,
            snapshot: snapshot
        )

        let decision = RuntimeProbeStateMachine.livenessRestartDecision(
            probes: probes,
            snapshot: snapshot,
            desired: DesiredRuntimeService(
                identity: RuntimeServiceIdentity(
                    projectName: "demo",
                    serviceName: "api"
                ),
                image: "example@sha256:abc",
                restartPolicy: .onFailure
            ),
            restartState: nil,
            currentTimestamp: "2026-07-23T00:00:00Z"
        )

        XCTAssertEqual(
            RuntimeProbeStateMachine.liveness(probes: probes, snapshot: snapshot),
            .unhealthy
        )
        XCTAssertEqual(
            decision?.executionAvailability,
            .availableForRestartManagedService
        )
    }

    func testUnavailableLivenessIsExplicitAndDoesNotRestartWorkload() throws {
        let probes = RuntimeProbeSet(
            liveness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/live"]))
            )
        )
        var snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )
        snapshot = try apply(
            .unavailable,
            kind: .liveness,
            at: 0,
            probes: probes,
            snapshot: snapshot
        )

        XCTAssertEqual(snapshot.state(for: .liveness)?.phase, .unavailable)
        XCTAssertEqual(
            RuntimeProbeStateMachine.liveness(probes: probes, snapshot: snapshot),
            .unavailable
        )
        XCTAssertEqual(
            try RuntimeProbeStateMachine.nextDirective(
                probes: probes,
                snapshot: snapshot,
                nowMilliseconds: 1_000
            ),
            .terminalFailure(.liveness)
        )
        XCTAssertNil(
            RuntimeProbeStateMachine.livenessRestartDecision(
                probes: probes,
                snapshot: snapshot,
                desired: DesiredRuntimeService(
                    identity: RuntimeServiceIdentity(
                        projectName: "demo",
                        serviceName: "api"
                    ),
                    image: "example@sha256:abc",
                    restartPolicy: .unlessStopped
                ),
                restartState: nil,
                currentTimestamp: "2026-07-23T00:00:00Z"
            )
        )
    }

    func testExecutingAttemptIsResumableWithoutCountingAFalseFailure() throws {
        let probes = RuntimeProbeSet(
            readiness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"]))
            )
        )
        let initial = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )
        let started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .readiness,
            probes: probes,
            snapshot: initial,
            nowMilliseconds: 0
        )
        let encoded = try JSONEncoder().encode(started.snapshot)
        let restored = try JSONDecoder().decode(RuntimeProbeSnapshot.self, from: encoded)
        let resumed = try RuntimeProbeStateMachine.resumed(
            restored,
            probes: probes,
            nowMilliseconds: 500
        )

        XCTAssertNil(resumed.state(for: .readiness)?.inFlightAttempt)
        XCTAssertEqual(resumed.state(for: .readiness)?.consecutiveFailures, 0)
        XCTAssertEqual(resumed.state(for: .readiness)?.attemptCount, 1)
        guard case .execute(let request) = try RuntimeProbeStateMachine.nextDirective(
            probes: probes,
            snapshot: resumed,
            nowMilliseconds: 500
        ) else {
            return XCTFail("Expected the interrupted read-only probe to become retryable.")
        }
        XCTAssertEqual(request.attempt, 2)
    }

    func testStaleAttemptResultIsRejected() throws {
        let probes = RuntimeProbeSet(
            readiness: RuntimeProbeConfiguration(
                action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"]))
            )
        )
        let snapshot = RuntimeProbeStateMachine.initialSnapshot(
            resourceIdentifier: "service-1",
            probes: probes,
            startedAtMilliseconds: 0
        )
        let started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: .readiness,
            probes: probes,
            snapshot: snapshot,
            nowMilliseconds: 0
        )
        let stale = RuntimeProbeExecutionRequest(
            resourceIdentifier: "service-1",
            kind: .readiness,
            attempt: 99,
            action: .exec(RuntimeProbeExecAction(command: ["/bin/ready"])),
            timeoutSeconds: 5
        )

        XCTAssertThrowsError(
            try RuntimeProbeStateMachine.record(
                RuntimeProbeAttemptResult(outcome: .succeeded, completedAtMilliseconds: 1),
                request: stale,
                probes: probes,
                snapshot: started.snapshot
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .staleAttempt)
        }
    }

    func testRedirectPolicyAllowsAtMostThreeSameOriginLoopbackRedirects() throws {
        let original = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/health"))
        let sameOrigin = try XCTUnwrap(URL(string: "http://127.0.0.1:8080/ready"))
        let external = try XCTUnwrap(URL(string: "http://example.test:8080/ready"))
        let changedPort = try XCTUnwrap(URL(string: "http://127.0.0.1:8081/ready"))

        XCTAssertEqual(
            try RuntimeProbeRedirectPolicy.validate(
                originalURL: original,
                proposedURL: sameOrigin,
                redirectsFollowed: 2
            ),
            sameOrigin
        )
        XCTAssertThrowsError(
            try RuntimeProbeRedirectPolicy.validate(
                originalURL: original,
                proposedURL: sameOrigin,
                redirectsFollowed: 3
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .redirectLimitExceeded)
        }
        XCTAssertThrowsError(
            try RuntimeProbeRedirectPolicy.validate(
                originalURL: original,
                proposedURL: external,
                redirectsFollowed: 0
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .redirectNotLoopback)
        }
        XCTAssertThrowsError(
            try RuntimeProbeRedirectPolicy.validate(
                originalURL: original,
                proposedURL: changedPort,
                redirectsFollowed: 0
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProbeValidationError, .redirectChangedOrigin)
        }
    }

    func testAttemptDiagnosticsAreBounded() {
        let result = RuntimeProbeAttemptResult(
            outcome: .failed,
            completedAtMilliseconds: 0,
            diagnosticRedacted: String(repeating: "é", count: 5_000)
        )

        XCTAssertLessThanOrEqual(
            result.diagnosticRedacted.utf8.count,
            RuntimeProbeAttemptResult.maximumDiagnosticBytes
        )
    }

    private func apply(
        _ outcome: RuntimeProbeAttemptOutcome,
        kind: RuntimeProbeKind,
        at milliseconds: Int64,
        probes: RuntimeProbeSet,
        snapshot: RuntimeProbeSnapshot
    ) throws -> RuntimeProbeSnapshot {
        let started = try RuntimeProbeStateMachine.markAttemptStarted(
            kind: kind,
            probes: probes,
            snapshot: snapshot,
            nowMilliseconds: milliseconds
        )
        return try RuntimeProbeStateMachine.record(
            RuntimeProbeAttemptResult(
                outcome: outcome,
                completedAtMilliseconds: milliseconds
            ),
            request: started.request,
            probes: probes,
            snapshot: started.snapshot
        )
    }
}
