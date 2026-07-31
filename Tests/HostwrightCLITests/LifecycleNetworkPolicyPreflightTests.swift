import HostwrightNetworking
import HostwrightRuntime
import XCTest
@testable import HostwrightCLI

final class LifecycleNetworkPolicyPreflightTests: XCTestCase {
    func testAppleCLIAndUnavailableContainerizationRefuseBeforeMutation()
        throws
    {
        for (providerID, capabilities) in [
            (RuntimeProviderID.appleContainerCLI,
             RuntimeNetworkProviderCapabilities.appleContainerCLI),
            (RuntimeProviderID.appleContainerization,
             RuntimeNetworkProviderCapabilities.appleContainerizationUnavailable)
        ] {
            XCTAssertThrowsError(
                try lifecyclePreflightNetworkPolicyCapabilities(
                    services: [service()],
                    providerID: providerID,
                    capabilities: capabilities
                )
            ) { error in
                guard case RuntimeAdapterError
                    .mutationUnavailableByPolicy(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(message.contains("No runtime mutation was attempted."))
            }
        }
    }

    func testQualifiedCapabilitiesAcceptExactIngressAndEgressPolicy()
        throws
    {
        XCTAssertNoThrow(
            try lifecyclePreflightNetworkPolicyCapabilities(
                services: [service()],
                providerID: .appleContainerization,
                capabilities: qualifiedCapabilities()
            )
        )
    }

    func testCIDRAndDNSRulesRequireTheirOwnQualifiedEnforcement()
        throws
    {
        let cidrService = service(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        address: "10.42.0.0/24",
                        port: 443
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try lifecyclePreflightNetworkPolicyCapabilities(
                services: [cidrService],
                providerID: .appleContainerization,
                capabilities: qualifiedCapabilities(enforcesCIDR: false)
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("CIDR"))
            XCTAssertTrue(
                String(describing: error).contains(
                    "No runtime mutation was attempted."
                )
            )
        }

        let dnsService = service(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        port: 443,
                        dns: "api.example.test"
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try lifecyclePreflightNetworkPolicyCapabilities(
                services: [dnsService],
                providerID: .appleContainerization,
                capabilities: qualifiedCapabilities(enforcesDNS: false)
            )
        ) { error in
                XCTAssertTrue(String(describing: error).contains("DNS-aware"))
                XCTAssertTrue(
                    String(describing: error).contains(
                        "No runtime mutation was attempted."
                    )
                )
            }
    }

    private func service(
        policy: HostwrightServiceNetworkPolicy = HostwrightServiceNetworkPolicy(
            ingress: [
                HostwrightNetworkPolicyRule(
                    project: "demo",
                    service: "gateway",
                    identity: "spiffe://hostwright/demo/gateway",
                    protocolName: .tcp,
                    port: 8_080
                )
            ],
            egress: [
                HostwrightNetworkPolicyRule(
                    project: "demo",
                    service: "database",
                    identity: "spiffe://hostwright/demo/database",
                    protocolName: .tcp,
                    port: 5_432
                )
            ]
        )
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            ),
            image: "example.invalid/api@sha256:\(String(repeating: "a", count: 64))",
            networkPolicy: policy
        )
    }

    private func qualifiedCapabilities(
        enforcesCIDR: Bool = true,
        enforcesDNS: Bool = true
    ) -> RuntimeNetworkProviderCapabilities {
        RuntimeNetworkProviderCapabilities(
            providerID: .appleContainerization,
            operations: [],
            modes: [],
            ipv4AddressModes: [],
            ipv6AddressModes: [],
            attachmentTiming: .unavailable,
            networkPolicy: RuntimeNetworkPolicyProviderCapabilities(
                state: .available,
                reason: .implemented,
                directions: HostwrightNetworkPolicyDirection.allCases,
                enforcesExactIdentity: true,
                enforcesCIDR: enforcesCIDR,
                enforcesDNS: enforcesDNS,
                appliesAtomicGenerations: true,
                observesRuleDigest: true
            )
        )
    }
}
