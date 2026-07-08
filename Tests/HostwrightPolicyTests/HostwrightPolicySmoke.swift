import HostwrightManifest
import HostwrightPolicy
import HostwrightRuntime
import XCTest

final class HostwrightPolicySmoke: XCTestCase {
    func testPlanningPolicyDecisionsPreserveCurrentSafetyMessages() {
        let desired = desiredState(
            services: [
                desiredService(
                    name: "api",
                    environment: [
                        RuntimeEnvironmentValue(name: "API_TOKEN", value: "token=plain-secret-token", isSensitive: true)
                    ],
                    ports: [
                        RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "0.0.0.0")
                    ],
                    mounts: [
                        RuntimeMountReference(source: "/", target: "/host", access: .readOnly)
                    ]
                ),
                desiredService(
                    name: "admin",
                    ports: [
                        RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "0.0.0.0")
                    ]
                ),
                DesiredRuntimeService(
                    identity: RuntimeServiceIdentity(projectName: "", serviceName: ""),
                    image: "ghcr.io/example/invalid:latest"
                )
            ]
        )
        let observed = observedState([
            observed(
                serviceName: "other",
                ports: [RuntimePortMapping(hostPort: 80, containerPort: 8080, bindAddress: "127.0.0.1")]
            )
        ])

        let decisions = LocalPolicyEvaluator.default.evaluate(desiredState: desired, observedState: observed)

        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .invalidDesiredIdentity &&
                $0.message == "Desired service identity must include a project and service name."
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .duplicateDesiredHostPort &&
                $0.message == "Desired host port 80 conflicts with demo/api." &&
                $0.stableDetailKey == "0.0.0.0:80/tcp"
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .observedHostPortConflict &&
                $0.message == "Desired host port 80 conflicts with observed demo/other on 127.0.0.1."
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .unsafeExposure &&
                $0.message == "Desired bind address is broader than the first-release policy allows."
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .privilegedHostPort &&
                $0.message == "Desired host port 80 is privileged; confirmed create rejects privileged host ports."
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .unsafeMountSource &&
                $0.message == "Unsafe host mount source is blocked by planning policy."
        })
        XCTAssertTrue(decisions.contains {
            $0.reasonCode == .secretValueRedacted &&
                $0.message == "Desired environment value for API_TOKEN is treated as sensitive and redacted from plans."
        })
        XCTAssertFalse(decisions.map(\.message).joined(separator: "\n").contains("plain-secret-token"))
    }

    func testPolicyEvaluationIsDeterministic() {
        let desired = desiredState(
            services: [
                desiredService(name: "api", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]),
                desiredService(name: "admin", ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)])
            ]
        )

        let first = LocalPolicyEvaluator.default.evaluate(desiredState: desired)
        let second = LocalPolicyEvaluator.default.evaluate(desiredState: desired)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.orderingKey), second.map(\.orderingKey))
    }

    func testImagePolicyExplainsDigestRequirementWithoutRegistryCalls() {
        let evaluator = LocalPolicyEvaluator(
            configuration: LocalPolicyConfiguration(imagePolicy: .requireDigest)
        )

        let decisions = evaluator.evaluateImageReference("ghcr.io/example/api:latest", serviceName: "api")

        XCTAssertEqual(decisions.map(\.reasonCode), [.imageDigestRequired])
        XCTAssertEqual(decisions.first?.severity, .blocker)
        XCTAssertTrue(decisions.first?.message.contains("require-digest") == true)
        XCTAssertTrue(decisions.first?.remediation.contains("OCI image reference") == true)
    }

    func testSecretReferenceUnavailableFailsClosedWithoutLeakingReferenceLabel() {
        let decisions = LocalPolicyEvaluator.default.evaluateSecretReference(
            name: "API_TOKEN",
            reference: "keychain://hostwright.api/api-token",
            isResolved: false,
            identity: identity()
        )

        XCTAssertEqual(decisions.map(\.reasonCode), [.secretReferenceUnavailable])
        XCTAssertEqual(decisions.first?.severity, .blocker)
        XCTAssertFalse(decisions.map(\.message).joined().contains("hostwright.api"))
        XCTAssertFalse(decisions.map(\.stableDetailKey).joined().contains("api-token"))
    }

    func testCleanupPolicyClassifiesExactEligibilityAndBlockedStates() {
        let eligible = LocalPolicyEvaluator.default.evaluateCleanupOwnership(
            CleanupOwnershipPolicyInput(
                cleanupEligible: true,
                resourceType: "container",
                ownershipProjectID: "project-demo",
                expectedProjectID: "project-demo",
                resourceIdentifier: "hostwright-demo-api",
                serviceName: "api",
                ownershipRuntimeAdapter: "AppleContainerApplyAdapter",
                observedAdapterName: "AppleContainerApplyAdapter",
                observedServices: [observed(lifecycleState: .stopped)]
            )
        )
        XCTAssertEqual(eligible.classification, .eligible)
        XCTAssertEqual(eligible.reason, "exact Hostwright-owned non-running container")
        XCTAssertEqual(eligible.decision.severity, .allow)

        let running = LocalPolicyEvaluator.default.evaluateCleanupOwnership(
            CleanupOwnershipPolicyInput(
                cleanupEligible: true,
                resourceType: "container",
                ownershipProjectID: "project-demo",
                expectedProjectID: "project-demo",
                resourceIdentifier: "hostwright-demo-api",
                serviceName: "api",
                ownershipRuntimeAdapter: "AppleContainerApplyAdapter",
                observedAdapterName: "AppleContainerApplyAdapter",
                observedServices: [observed(lifecycleState: .running)]
            )
        )
        XCTAssertEqual(running.classification, .running)
        XCTAssertEqual(running.reason, "running containers are never deleted by cleanup")
        XCTAssertEqual(running.decision.severity, .blocker)

        let missingAdapter = LocalPolicyEvaluator.default.evaluateCleanupOwnership(
            CleanupOwnershipPolicyInput(
                cleanupEligible: true,
                resourceType: "container",
                ownershipProjectID: "project-demo",
                expectedProjectID: "project-demo",
                resourceIdentifier: "hostwright-demo-api",
                serviceName: "api",
                ownershipRuntimeAdapter: "AppleContainerApplyAdapter",
                observedAdapterName: nil,
                observedServices: [observed(lifecycleState: .stopped)]
            )
        )
        XCTAssertEqual(missingAdapter.classification, .blocked)
        XCTAssertEqual(missingAdapter.reason, "runtime adapter metadata is unavailable")

        let observedOnly = LocalPolicyEvaluator.default.evaluateObservedOnlyCleanup(
            resourceIdentifier: "hostwright-demo-api",
            observedServices: [observed(lifecycleState: .stopped)]
        )
        XCTAssertEqual(observedOnly.classification, .neverDelete)
        XCTAssertEqual(observedOnly.reason, "observed container has no Hostwright ownership record")
    }

    func testUnsupportedLifecycleManifestExposureAndAcceleratorsFailClosed() {
        let lifecycle = LocalPolicyEvaluator.default.evaluateLifecycleRequest(
            action: "user-facing restart",
            isSupportedNarrowPath: false,
            identity: identity()
        )
        XCTAssertEqual(lifecycle.reasonCode, .lifecycleUnsupported)
        XCTAssertEqual(lifecycle.severity, .blocker)

        let manifest = LocalPolicyEvaluator.default.evaluateUntrustedManifestUnsupportedField(
            field: "dns",
            context: "services.api"
        )
        XCTAssertEqual(manifest.reasonCode, .untrustedManifestUnsupportedField)
        XCTAssertEqual(manifest.severity, .blocker)

        let exposure = LocalPolicyEvaluator.default.evaluateSecureExposureRequest(scope: "cloudflare-tunnel")
        XCTAssertEqual(exposure.reasonCode, .secureExposureUnsupported)
        XCTAssertEqual(exposure.severity, .blocker)

        let accelerator = LocalPolicyEvaluator.default.evaluateAcceleratorRequest(feature: "Apple GPU")
        XCTAssertEqual(accelerator.reasonCode, .acceleratorUnsupported)
        XCTAssertEqual(accelerator.severity, .blocker)
    }

    private func identity(_ serviceName: String = "api") -> RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: serviceName)
    }

    private func desiredService(
        name: String = "api",
        environment: [RuntimeEnvironmentValue] = [],
        ports: [RuntimePortMapping] = [],
        mounts: [RuntimeMountReference] = []
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity(name),
            image: "ghcr.io/example/\(name):latest",
            environment: environment,
            ports: ports,
            mounts: mounts
        )
    }

    private func desiredState(services: [DesiredRuntimeService]) -> DesiredRuntimeState {
        DesiredRuntimeState(projectName: "demo", services: services)
    }

    private func observed(
        serviceName: String = "api",
        lifecycleState: RuntimeLifecycleState = .running,
        ports: [RuntimePortMapping] = []
    ) -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: identity(serviceName),
            image: "ghcr.io/example/\(serviceName):latest",
            lifecycleState: lifecycleState,
            healthState: .healthy,
            ports: ports
        )
    }

    private func observedState(_ services: [ObservedRuntimeService]) -> ObservedRuntimeState {
        ObservedRuntimeState(
            projectName: "demo",
            services: services
        )
    }
}
