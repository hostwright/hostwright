import HostwrightNetworking
import XCTest
@testable import HostwrightRuntime

final class ContainerizationGuestNetworkPolicyCompilerTests:
    XCTestCase
{
    func testAbsentPolicyAllowsOnlyExactSameProjectPeerAddresses() throws {
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [
                peer(
                    resourceUUID: peerUUID,
                    addresses: ["fd42::2/64", "10.42.0.2/24"]
                ),
                peer(
                    projectName: "other",
                    projectUUID: otherProjectUUID,
                    resourceUUID: otherPeerUUID,
                    addresses: ["192.0.2.9"]
                ),
                peer(
                    resourceUUID: serviceUUID,
                    addresses: ["10.42.0.1"]
                )
            ],
            dnsServers: ["2001:4860:4860::8888", "1.1.1.1"]
        )

        let result = try compile(policy: nil, inputs: inputs)

        XCTAssertEqual(result.ingressDefault, .allowSameProject)
        XCTAssertEqual(result.egressDefault, .allowSameProject)
        XCTAssertEqual(
            Set(result.ingress),
            Set([
                try rule("10.42.0.2/32", .tcp),
                try rule("10.42.0.2/32", .udp),
                try rule("fd42::2/128", .tcp),
                try rule("fd42::2/128", .udp)
            ])
        )
        XCTAssertEqual(result.egress, result.ingress)
        XCTAssertEqual(
            result.dnsServers,
            ["1.1.1.1", "2001:4860:4860::8888"]
        )
    }

    func testExplicitSelectorsResolveAndIntersectWithoutWidening() throws {
        let identity = "spiffe://hostwright.test/api"
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [
                peer(
                    serviceName: "api",
                    resourceUUID: peerUUID,
                    identities: [identity],
                    addresses: ["10.42.0.2", "fd42::2"]
                ),
                peer(
                    serviceName: "api",
                    resourceUUID: secondPeerUUID,
                    identities: ["spiffe://hostwright.test/other"],
                    addresses: ["10.42.1.2"]
                )
            ]
        )
        let policy = HostwrightServiceNetworkPolicy(
            ingress: [
                HostwrightNetworkPolicyRule(
                    project: "project",
                    service: "api",
                    identity: identity,
                    protocolName: .tcp,
                    address: "10.42.0.0/24",
                    port: 443
                )
            ],
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .udp,
                    port: 5353
                )
            ]
        )

        let result = try compile(policy: policy, inputs: inputs)

        XCTAssertEqual(result.ingressDefault, .deny)
        XCTAssertEqual(result.egressDefault, .deny)
        XCTAssertEqual(
            result.ingress,
            [try rule("10.42.0.2/32", .tcp, port: 443)]
        )
        XCTAssertEqual(
            Set(result.egress),
            Set([
                try rule("0.0.0.0/0", .udp, port: 5353),
                try rule("::/0", .udp, port: 5353)
            ])
        )
    }

    func testUnknownIdentityFailsAndKnownUnaddressedPeerCompilesNoAllow()
        throws
    {
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [
                peer(
                    serviceName: "api",
                    resourceUUID: peerUUID,
                    identities: ["spiffe://hostwright.test/api"],
                    addresses: []
                )
            ]
        )

        XCTAssertThrowsError(
            try compile(
                policy: HostwrightServiceNetworkPolicy(
                    egress: [
                        HostwrightNetworkPolicyRule(
                            identity: "spiffe://hostwright.test/missing",
                            protocolName: .tcp
                        )
                    ]
                ),
                inputs: inputs
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .unknownIdentity("spiffe://hostwright.test/missing")
            )
        }

        let result = try compile(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        service: "api",
                        protocolName: .tcp
                    )
                ]
            ),
            inputs: inputs
        )
        XCTAssertEqual(result.egressDefault, .deny)
        XCTAssertEqual(result.egress, [])
    }

    func testDNSResolutionIsExactAndIntersectsAddressSelector() throws {
        let resolutions = try ContainerizationGuestDNSResolutionMap([
            "api.internal": ["2001:db8::42/64", "192.0.2.42/24"]
        ])
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            dnsResolutions: resolutions
        )
        let policy = HostwrightServiceNetworkPolicy(
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .tcp,
                    address: "2001:db8::/64",
                    port: 443,
                    dns: "api.internal"
                )
            ]
        )

        let result = try compile(policy: policy, inputs: inputs)

        XCTAssertEqual(
            result.egress,
            [try rule("2001:db8::42/128", .tcp, port: 443)]
        )
    }

    func testDNSResolutionChangeProducesNewPolicyDigest() throws {
        let policy = HostwrightServiceNetworkPolicy(
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .tcp,
                    port: 443,
                    dns: "api.internal"
                )
            ]
        )
        let first = try compile(
            policy: policy,
            inputs: try ContainerizationGuestNetworkPolicyInputs(
                dnsResolutions: try .init([
                    "api.internal": ["192.0.2.42"]
                ])
            )
        )
        let second = try compile(
            policy: policy,
            inputs: try ContainerizationGuestNetworkPolicyInputs(
                dnsResolutions: try .init([
                    "api.internal": ["192.0.2.43"]
                ])
            )
        )

        XCTAssertNotEqual(first.egress, second.egress)
        XCTAssertNotEqual(first.sha256, second.sha256)
    }

    func testUnknownDNSFailsWhileEmptyAndDisjointDNSCompileNoAllow()
        throws
    {
        let missingInputs = try ContainerizationGuestNetworkPolicyInputs()
        let policy = HostwrightServiceNetworkPolicy(
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .tcp,
                    dns: "api.internal"
                )
            ]
        )
        XCTAssertThrowsError(
            try compile(policy: policy, inputs: missingInputs)
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .unknownDNS("api.internal")
            )
        }

        let emptyInputs = try ContainerizationGuestNetworkPolicyInputs(
            dnsResolutions: try .init(["api.internal": []])
        )
        XCTAssertEqual(
            try compile(policy: policy, inputs: emptyInputs).egress,
            []
        )

        let disjointRule = HostwrightNetworkPolicyRule(
            protocolName: .tcp,
            address: "198.51.100.0/24",
            dns: "api.internal"
        )
        let disjointInputs = try ContainerizationGuestNetworkPolicyInputs(
            dnsResolutions: try .init([
                "api.internal": ["192.0.2.42"]
            ])
        )
        XCTAssertEqual(
            try compile(
                policy: HostwrightServiceNetworkPolicy(
                    egress: [disjointRule]
                ),
                inputs: disjointInputs
            ).egress,
            []
        )
    }

    func testTrustedIngressGatewayPreservesProtocolAndPort() throws {
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            trustedIngressGateways: ["fd42::1/64", "10.42.0.1/24"]
        )
        let policy = HostwrightServiceNetworkPolicy(
            ingress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .tcp,
                    address: "192.0.2.0/24",
                    port: 8443
                )
            ]
        )

        let result = try compile(policy: policy, inputs: inputs)

        XCTAssertEqual(
            Set(result.ingress),
            Set([
                try rule("10.42.0.1/32", .tcp, port: 8443),
                try rule("192.0.2.0/24", .tcp, port: 8443),
                try rule("fd42::1/128", .tcp, port: 8443)
            ])
        )
    }

    func testTrustedIngressGatewayIsNeverAddedToAbsentOrEgressPolicy()
        throws
    {
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [
                peer(
                    resourceUUID: peerUUID,
                    addresses: ["10.42.0.2"]
                )
            ],
            trustedIngressGateways: ["10.42.0.1"]
        )
        let absent = try compile(policy: nil, inputs: inputs)
        XCTAssertFalse(
            absent.ingress.contains {
                $0.address == "10.42.0.1/32"
            }
        )

        let explicit = try compile(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        address: "192.0.2.0/24",
                        port: 443
                    )
                ]
            ),
            inputs: inputs
        )
        XCTAssertFalse(
            explicit.egress.contains {
                $0.address == "10.42.0.1/32"
            }
        )
    }

    func testGatewayAnyPortExistsOnlyWhenSourceRuleHasNoPort() throws {
        let result = try compile(
            policy: HostwrightServiceNetworkPolicy(
                ingress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .udp,
                        address: "192.0.2.0/24"
                    )
                ]
            ),
            inputs: try ContainerizationGuestNetworkPolicyInputs(
                trustedIngressGateways: ["10.42.0.1"]
            )
        )

        XCTAssertEqual(
            result.ingress.first {
                $0.address == "10.42.0.1/32"
            }?.port,
            nil
        )
        XCTAssertEqual(
            result.ingress.first {
                $0.address == "10.42.0.1/32"
            }?.protocolName,
            .udp
        )
    }

    func testCompilerIsDeterministicAcrossInputOrderingAndDuplicates()
        throws
    {
        let firstPeer = try peer(
            serviceName: "api",
            resourceUUID: peerUUID,
            identities: [
                "spiffe://hostwright.test/b",
                "spiffe://hostwright.test/a",
                "spiffe://hostwright.test/a"
            ],
            addresses: ["fd42::2", "10.42.0.2", "10.42.0.2/24"]
        )
        let secondPeer = try peer(
            serviceName: "worker",
            resourceUUID: secondPeerUUID,
            addresses: ["10.42.0.3"]
        )
        let firstInputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [firstPeer, secondPeer],
            dnsResolutions: try .init([
                "api.internal": ["fd42::8", "192.0.2.8"]
            ]),
            dnsServers: ["2001:4860:4860::8888", "1.1.1.1"],
            trustedIngressGateways: ["fd42::1", "10.42.0.1"]
        )
        let secondInputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: [secondPeer, firstPeer],
            dnsResolutions: try .init([
                "api.internal": ["192.0.2.8", "fd42::8"]
            ]),
            dnsServers: ["1.1.1.1", "2001:4860:4860::8888"],
            trustedIngressGateways: ["10.42.0.1", "fd42::1"]
        )
        let policy = HostwrightServiceNetworkPolicy(
            ingress: [
                HostwrightNetworkPolicyRule(
                    service: "api",
                    protocolName: .tcp,
                    port: 443
                )
            ],
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .udp,
                    dns: "api.internal"
                )
            ]
        )

        let first = try compile(policy: policy, inputs: firstInputs)
        let second = try compile(policy: policy, inputs: secondInputs)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sha256, second.sha256)
    }

    func testExpansionBeyondGuestDocumentLimitFailsClosed() throws {
        let peers = try (0..<2_048).map { index in
            try peer(
                resourceUUID: String(
                    format: "00000000-0000-4000-8000-%012x",
                    index + 1
                ),
                addresses: [
                    "10.\(index / 256).\(index % 256).1",
                    "fd42:\(String(index, radix: 16))::1"
                ]
            )
        }
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: peers
        )

        XCTAssertThrowsError(
            try compile(policy: nil, inputs: inputs)
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .tooManyExpandedRules(.ingress)
            )
        }
    }

    func testInputBoundsAndCanonicalAddressValidation() throws {
        XCTAssertThrowsError(
            try peer(
                resourceUUID: peerUUID,
                addresses: ["not-an-address"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .invalidPeerAddress(
                    peer: peerUUID,
                    address: "not-an-address"
                )
            )
        }
        XCTAssertThrowsError(
            try ContainerizationGuestDNSResolutionMap([
                "Not Canonical": ["192.0.2.1"]
            ])
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .invalidDNSName("Not Canonical")
            )
        }
        XCTAssertThrowsError(
            try ContainerizationGuestNetworkPolicyInputs(
                dnsServers: ["192.0.2.1/32"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyCompilerError,
                .invalidDNSServer("192.0.2.1/32")
            )
        }
    }

    private func compile(
        policy: HostwrightServiceNetworkPolicy?,
        inputs: ContainerizationGuestNetworkPolicyInputs
    ) throws -> ContainerizationGuestNetworkPolicy {
        try ContainerizationGuestNetworkPolicyCompiler.compile(
            projectName: "project",
            projectUUID: projectUUID,
            generation: 7,
            serviceName: "web",
            serviceResourceUUID: serviceUUID,
            policy: policy,
            inputs: inputs
        )
    }

    private func peer(
        projectName: String = "project",
        projectUUID: String? = nil,
        serviceName: String = "api",
        resourceUUID: String,
        identities: [String] = [],
        addresses: [String]
    ) throws -> ContainerizationGuestNetworkPeer {
        try ContainerizationGuestNetworkPeer(
            projectName: projectName,
            projectUUID: projectUUID ?? self.projectUUID,
            serviceName: serviceName,
            resourceUUID: resourceUUID,
            identities: identities,
            assignedAddresses: addresses
        )
    }

    private func rule(
        _ address: String,
        _ protocolName: HostwrightNetworkPolicyProtocol,
        port: Int? = nil
    ) throws -> ContainerizationGuestNetworkPolicyRule {
        try ContainerizationGuestNetworkPolicyRule(
            address: address,
            port: port,
            protocolName: protocolName
        )
    }

    private let projectUUID =
        "11111111-1111-4111-8111-111111111111"
    private let serviceUUID =
        "22222222-2222-4222-8222-222222222222"
    private let peerUUID =
        "33333333-3333-4333-8333-333333333333"
    private let secondPeerUUID =
        "44444444-4444-4444-8444-444444444444"
    private let otherProjectUUID =
        "55555555-5555-4555-8555-555555555555"
    private let otherPeerUUID =
        "66666666-6666-4666-8666-666666666666"
}
