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

    func testExtensionPolicyAllowsReviewedNonMutatingPolicyPackDeclaration() {
        let declaration = HostwrightExtensionDeclaration(
            identifier: "dev.hostwright.policy.local",
            kind: .policyPack,
            trust: .reviewedLocal,
            capabilities: [
                HostwrightExtensionCapabilityDeclaration(
                    capability: .policyEvaluation,
                    purpose: "explain local development policy",
                    boundaries: [.localPolicy, .redaction, .auditTrail, .noRuntimeMutation]
                )
            ]
        )

        let decisions = ExtensionPolicyEvaluator.default.evaluate(declaration)

        XCTAssertEqual(decisions.map(\.reasonCode), [.extensionDeclared])
        XCTAssertEqual(decisions.first?.severity, .allow)
        XCTAssertEqual(decisions.first?.category, .extension)
        XCTAssertTrue(decisions.first?.message.contains("non-mutating policyPack path") == true)
        XCTAssertTrue(decisions.first?.remediation.contains("does not load or run extension code") == true)
    }

    func testExtensionPolicyBlocksMutationAndMissingBoundaries() {
        let declaration = HostwrightExtensionDeclaration(
            identifier: "dev.hostwright.runtime.mutator",
            kind: .runtimeAdapter,
            trust: .reviewedLocal,
            capabilities: [
                HostwrightExtensionCapabilityDeclaration(
                    capability: .runtimeMutation,
                    purpose: "mutate runtime directly",
                    boundaries: [.runtimeAdapter, .localPolicy]
                )
            ]
        )

        let decisions = ExtensionPolicyEvaluator.default.evaluate(declaration)
        let reasonCodes = decisions.map(\.reasonCode)

        XCTAssertTrue(reasonCodes.contains(.extensionRuntimeMutationUnsupported))
        XCTAssertTrue(reasonCodes.contains(.extensionBoundaryMissing))
        XCTAssertTrue(decisions.allSatisfy { $0.severity == .blocker })
        XCTAssertTrue(decisions.contains { $0.message.contains("confirmationGate") })
        XCTAssertTrue(decisions.contains { $0.message.contains("ownershipGate") })
    }

    func testExtensionPolicyBlocksUntrustedTunnelAndSecretCapabilities() {
        let declaration = HostwrightExtensionDeclaration(
            identifier: "example.remote.tunnel",
            kind: .tunnelProvider,
            trust: .thirdParty,
            capabilities: [
                HostwrightExtensionCapabilityDeclaration(
                    capability: .tunnelExposure,
                    purpose: "create public tunnel",
                    boundaries: [.localPolicy, .redaction, .auditTrail, .confirmationGate, .localOnlyNoUpload]
                ),
                HostwrightExtensionCapabilityDeclaration(
                    capability: .secretResolution,
                    purpose: "resolve provider credential",
                    boundaries: [.localPolicy, .redaction, .auditTrail, .confirmationGate]
                )
            ]
        )

        let decisions = ExtensionPolicyEvaluator.default.evaluate(declaration)
        let reasonCodes = decisions.map(\.reasonCode)

        XCTAssertTrue(reasonCodes.contains(.extensionUntrusted))
        XCTAssertTrue(reasonCodes.contains(.extensionTunnelUnsupported))
        XCTAssertTrue(reasonCodes.contains(.extensionSecretResolutionUnsupported))
        XCTAssertFalse(reasonCodes.contains(.extensionDeclared))
        XCTAssertFalse(decisions.map(\.message).joined(separator: "\n").localizedCaseInsensitiveContains("tunnel is supported"))
    }

    func testExtensionPolicyFailsClosedForEmptyOrUnsupportedDeclarations() {
        let declaration = HostwrightExtensionDeclaration(
            identifier: "",
            kind: .future,
            apiVersion: 2,
            trust: .untrusted,
            capabilities: []
        )

        let decisions = ExtensionPolicyEvaluator.default.evaluate(declaration)
        let reasonCodes = decisions.map(\.reasonCode)

        XCTAssertEqual(
            Set(reasonCodes),
            Set([
                .extensionMissingIdentity,
                .extensionNoCapabilities,
                .extensionUnsupportedAPIVersion,
                .extensionUntrusted
            ])
        )
        XCTAssertTrue(decisions.allSatisfy { $0.severity == .blocker })
    }

    func testExtensionPolicyEvaluationIsDeterministic() {
        let declaration = HostwrightExtensionDeclaration(
            identifier: "dev.hostwright.control.surface",
            kind: .controlSurfaceIntegration,
            trust: .builtIn,
            capabilities: [
                HostwrightExtensionCapabilityDeclaration(
                    capability: .controlSurfaceRead,
                    purpose: "read command output",
                    boundaries: [.localPolicy, .redaction, .auditTrail, .explicitStatePath, .noRuntimeMutation]
                ),
                HostwrightExtensionCapabilityDeclaration(
                    capability: .stateRead,
                    purpose: "read explicit state",
                    boundaries: [.stateStore, .explicitStatePath, .redaction, .auditTrail, .noRuntimeMutation]
                ),
                HostwrightExtensionCapabilityDeclaration(
                    capability: .stateWrite,
                    purpose: "write direct state",
                    boundaries: [.stateStore, .localPolicy, .redaction, .auditTrail, .explicitStatePath]
                )
            ]
        )

        let first = ExtensionPolicyEvaluator.default.evaluate(declaration)
        let second = ExtensionPolicyEvaluator.default.evaluate(declaration)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.orderingKey), second.map(\.orderingKey))
        XCTAssertEqual(first.map(\.reasonCode), [.extensionStateWriteUnsupported, .extensionDeclared, .extensionDeclared])
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
