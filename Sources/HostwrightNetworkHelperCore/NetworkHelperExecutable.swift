import Foundation
import HostwrightNetworking
import HostwrightRuntime

public enum NetworkHelperExecutable {
    public static func run(
        runtimeDirectoryURL: URL,
        idleTimeoutMilliseconds: Int64 = 30_000,
        tunnelStore:
            (any HostwrightTunnelIntentPersisting)? = nil
    ) throws {
        let runtimeDirectory =
            try ContainerizationHelperRuntimeDirectory.prepare(
                at: runtimeDirectoryURL,
                socketName: "network-helper.sock"
            )
        let stateRoot = runtimeDirectoryURL.appendingPathComponent(
            "dns-state",
            isDirectory: true
        )
        let store = try NetworkHelperStateStore(rootURL: stateRoot)
        let providerCoordinator =
            try NetworkHelperProviderCoordinator(
                stateRootURL: runtimeDirectoryURL.appendingPathComponent(
                    "provider-state",
                    isDirectory: true
                )
            )
        let hostAccessBroker = NetworkHelperHostAccessBroker()
        let ingressBroker = NetworkHelperIngressBroker()
        let certificateCoordinator =
            NetworkHelperCertificateCoordinator()
        let tunnelManager = tunnelStore.map {
            NetworkHelperServiceTunnelManager(
                store: $0,
                certificateCoordinator: certificateCoordinator
            )
        }
        let policyBroker = NetworkHelperPolicyBroker()
        let policyConfigurations =
            try store.activePolicyConfigurations()
        let policiesByIdentity = Dictionary(
            uniqueKeysWithValues: policyConfigurations.map {
                ($0.identity, $0)
            }
        )
        for configuration in policyConfigurations {
            guard try policyBroker.apply(
                identity: configuration.identity,
                plan: configuration.plan
            ) == configuration.sha256 else {
                throw NetworkHelperError.quarantined
            }
        }
        for configuration
            in try store.activeHostAccessConfigurations() {
            do {
                guard try hostAccessBroker.apply(
                    identity: configuration.identity,
                    bindings: configuration.bindings
                ) == configuration.sha256 else {
                    throw NetworkHelperError.bindingUnavailable
                }
            } catch NetworkHelperError.bindingUnavailable {
                // The project bridge may not exist until its first attached
                // container starts. The server must remain available so the
                // same persisted generation can be re-observed and activated.
            }
        }
        for configuration
            in try store.activeCertificateConfigurations() {
            do {
                let activation = try certificateCoordinator.apply(
                    identity: configuration.identity,
                    bindings: configuration.bindings,
                    persistedEvidence: try store.certificateEvidence(
                        identity: configuration.identity
                    ),
                    overlapEvidence:
                        try store.retiredCertificateEvidence(
                            identity: configuration.identity
                        )
                )
                _ = try store.recordCertificateEvidence(
                    identity: configuration.identity,
                    certificates: activation.evidence
                )
            } catch NetworkHelperError.certificateUnavailable {
                // A locked or unavailable Keychain leaves TLS listeners
                // inactive while the exact generation remains resumable.
            }
        }
        for configuration in try store.activeIngressConfigurations() {
            do {
                let policyConfiguration =
                    policiesByIdentity[configuration.identity]
                let policyAuthorizer:
                    (@Sendable (NetworkPolicyFlow) -> Bool)?
                if let policy = policyConfiguration {
                    policyAuthorizer = { [policyBroker] flow in
                        policyBroker.allows(
                            identity: configuration.identity,
                            expectedSHA256: policy.sha256,
                            flow: flow
                        )
                    }
                } else {
                    policyAuthorizer = nil
                }
                let activation = certificateCoordinator.activation(
                    identity: configuration.identity
                )
                if configuration.bindings.contains(where: {
                    $0.certificate != nil
                }), activation == nil {
                    continue
                }
                guard try ingressBroker.apply(
                    identity: configuration.identity,
                    bindings: configuration.bindings,
                    certificateIdentities:
                        activation?.identities ?? [:],
                    policySHA256: policyConfiguration?.sha256,
                    policyAuthorizer: policyAuthorizer,
                    mutualTLSPolicies:
                        activation?.mutualTLSPolicies ?? [:]
                ) == configuration.sha256 else {
                    throw NetworkHelperError.bindingUnavailable
                }
                if let retired = try store
                    .retiredCertificateEvidence(
                        identity: configuration.identity
                    ) {
                    if !configuration.bindings.isEmpty {
                        guard try ingressBroker.apply(
                            identity: configuration.identity,
                            bindings: configuration.bindings,
                            certificateIdentities:
                                activation?.identities ?? [:],
                            policySHA256:
                                policyConfiguration?.sha256,
                            policyAuthorizer: policyAuthorizer,
                            mutualTLSPolicies:
                                activation?
                                    .currentMutualTLSPolicies ?? [:]
                        ) == configuration.sha256 else {
                            throw NetworkHelperError
                                .bindingUnavailable
                        }
                    }
                    try certificateCoordinator.cleanup(
                        identity: retired.identity,
                        evidence: retired
                    )
                    try store.clearRetiredCertificateEvidence(
                        identity: configuration.identity,
                        expected: retired
                    )
                }
            } catch NetworkHelperError.bindingUnavailable {
                // A conflicting local listener remains inactive while the
                // persisted generation stays available for exact recovery.
            } catch NetworkHelperError.certificateUnavailable {
                // The TLS listener remains inactive until its exact identity
                // becomes available without replacing the persisted request.
            }
        }
        let server = NetworkHelperUnixServer(
            runtimeDirectory: runtimeDirectory,
            dispatcher: NetworkHelperDispatcher(
                store: store,
                hostAccessBroker: hostAccessBroker,
                ingressBroker: ingressBroker,
                certificateCoordinator: certificateCoordinator,
                policyBroker: policyBroker,
                providerCoordinator: providerCoordinator,
                tunnelManager: tunnelManager
            ),
            authenticator: .productionClient(),
            idleTimeoutMilliseconds: idleTimeoutMilliseconds
        )
        try server.run()
    }
}
