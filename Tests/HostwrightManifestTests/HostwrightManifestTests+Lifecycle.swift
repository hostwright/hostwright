import Foundation
import XCTest
@testable import HostwrightManifest

extension HostwrightManifestTests {
    func testPhase08RestartBudgetsParseValidateAndRoundTripCanonically() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: api-local
            restartBudget:
              maxAttempts: 24
              window: 900s
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                restart:
                  policy: on-failure
                  maxAttempts: 7
                  window: 600s
                  backoff: 15s
                  maxBackoff: 120s
                  jitter: 5s
                  stableRun: 90s
                  priority: 20
            """
        )

        XCTAssertEqual(manifest.restartBudget, HostwrightProjectRestartBudget(maxAttempts: 24, window: 900))
        XCTAssertEqual(
            manifest.services[0].restart,
            HostwrightRestart(
                policy: "on-failure",
                maxAttempts: 7,
                window: 600,
                backoff: 15,
                maxBackoff: 120,
                jitter: 5,
                stableRun: 90,
                priority: 20
            )
        )
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)
    }

    func testPhase08RestartBudgetDefaultsPreserveLegacyCanonicalManifest() throws {
        let manifest = try ManifestValidator.validated(Self.validManifest)
        XCTAssertNil(manifest.restartBudget)
        XCTAssertEqual(manifest.services[0].restart, HostwrightRestart(policy: "on-failure"))
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertFalse(canonical.contains("restartBudget:"))
        XCTAssertFalse(canonical.contains("maxAttempts:"))
    }

    func testPhase08RolloutStableObservationParsesValidatesAndRoundTrips() throws {
        let manifest = try ManifestValidator.validated(
            """
            version: 3
            project: rollout-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                probes:
                  readiness:
                    exec: ["/bin/check-ready"]
                    interval: 1s
                update:
                  strategy: rolling
                  maxSurge: 1
                  maxUnavailable: 0
                  progressDeadline: 60s
                  stableObservation: 10s
            """
        )

        XCTAssertEqual(manifest.services[0].update.stableObservation, 10)
        let canonical = try ManifestCanonicalEncoder.encode(manifest)
        XCTAssertTrue(canonical.contains("stableObservation: \"10s\""))
        XCTAssertEqual(try ManifestValidator.validated(canonical), manifest)

        assertManifestFailure(
            """
            version: 3
            project: rollout-local
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
                update:
                  progressDeadline: 60s
                  stableObservation: 10s
            """,
            contains: "stableObservation requires a readiness or liveness probe"
        )
    }

    func testPhase08RestartBudgetsRejectUnsafeAndUnknownValues() {
        let invalidFields = [
            "maxAttempts: 0",
            "window: 0s",
            "backoff: 0s",
            "stableRun: 0s",
            "priority: 101"
        ]
        for fields in invalidFields {
            assertManifestFailure(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                    restart:
                      policy: on-failure
                      \(fields)
                """,
                contains: "restart"
            )
        }
        for fields in [
            "backoff: 60s\n      maxBackoff: 30s",
            "backoff: 60s\n      jitter: 61s"
        ] {
            assertManifestFailure(
                """
                version: 3
                project: api-local
                services:
                  api:
                    image: ghcr.io/example/api:latest
                    resources:
                      requests: {cpus: 1, memory: 512MiB}
                      limits: {cpus: 1, memory: 512MiB}
                    restart:
                      policy: on-failure
                      \(fields)
                """,
                contains: "restart"
            )
        }
        assertManifestFailure(
            """
            version: 3
            project: api-local
            restartBudget:
              maxAttempts: 1001
            services:
              api:
                image: ghcr.io/example/api:latest
                resources:
                  requests: {cpus: 1, memory: 512MiB}
                  limits: {cpus: 1, memory: 512MiB}
            """,
            contains: "restartBudget.maxAttempts"
        )
    }
}
