import Foundation
import XCTest
@testable import HostwrightNetworking

final class NetworkPolicyCompilerTests: XCTestCase {
    private let projectUUID = "11111111-1111-4111-8111-111111111111"

    func testAbsentPolicyPreservesOnlySameProjectConnectivity() throws {
        let plan = try compile(policy: nil)

        XCTAssertTrue(
            plan.allows(
                flow(
                    direction: .ingress,
                    sourceProject: "demo",
                    sourceService: "web",
                    destinationService: "api"
                )
            )
        )
        XCTAssertFalse(
            plan.allows(
                flow(
                    direction: .ingress,
                    sourceProject: "other",
                    sourceService: "web",
                    destinationService: "api"
                )
            )
        )
        XCTAssertFalse(
            plan.allows(
                flow(
                    direction: .egress,
                    sourceProject: "demo",
                    sourceService: "api",
                    destinationProject: "other",
                    destinationService: "database"
                )
            )
        )
    }

    func testExplicitPolicyDefaultsBothDirectionsToDeny() throws {
        let plan = try compile(
            policy: HostwrightServiceNetworkPolicy()
        )

        XCTAssertFalse(
            plan.allows(
                flow(
                    direction: .ingress,
                    sourceProject: "demo",
                    sourceService: "web",
                    destinationService: "api"
                )
            )
        )
        XCTAssertFalse(
            plan.allows(
                flow(
                    direction: .egress,
                    sourceProject: "demo",
                    sourceService: "api",
                    destinationService: "database"
                )
            )
        )
    }

    func testExactRuleRequiresEveryDeclaredDimension() throws {
        let rule = HostwrightNetworkPolicyRule(
            project: "demo",
            service: "web",
            identity: "spiffe://hostwright.internal/web",
            protocolName: .tcp,
            address: "10.20.0.0/24",
            port: 8443
        )
        let plan = try compile(
            policy: HostwrightServiceNetworkPolicy(ingress: [rule])
        )
        let accepted = flow(
            direction: .ingress,
            sourceProject: "demo",
            sourceService: "web",
            sourceIdentity: "spiffe://hostwright.internal/web",
            destinationService: "api",
            address: "10.20.0.42",
            port: 8443
        )

        XCTAssertTrue(plan.allows(accepted))
        XCTAssertFalse(
            plan.allows(
                replacing(
                    accepted,
                    sourceIdentity:
                        "spiffe://hostwright.internal/not-web"
                )
            )
        )
        XCTAssertFalse(
            plan.allows(replacing(accepted, address: "10.21.0.42"))
        )
        XCTAssertFalse(plan.allows(replacing(accepted, port: 8444)))
    }

    func testDNSChangeRemovesOldDecisionWithoutPermissiveUnion() throws {
        let initial = try compile(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        port: 443,
                        dns: "old.example.test"
                    )
                ]
            ),
            generation: 1
        )
        let replacement = try compile(
            policy: HostwrightServiceNetworkPolicy(
                egress: [
                    HostwrightNetworkPolicyRule(
                        protocolName: .tcp,
                        port: 443,
                        dns: "new.example.test"
                    )
                ]
            ),
            generation: 2
        )
        let old = flow(
            direction: .egress,
            sourceProject: "demo",
            sourceService: "api",
            destinationProject: "external",
            destinationService: "https",
            port: 443,
            dns: "old.example.test"
        )
        let new = replacing(old, dns: "new.example.test")

        XCTAssertTrue(initial.allows(old))
        XCTAssertFalse(initial.allows(new))
        XCTAssertFalse(replacement.allows(old))
        XCTAssertTrue(replacement.allows(new))
        XCTAssertNotEqual(initial.sha256, replacement.sha256)
    }

    func testCanonicalOrderingProducesStableDigestAndProjections() throws {
        let firstRule = HostwrightNetworkPolicyRule(
            service: "web",
            protocolName: .tcp,
            port: 8080
        )
        let secondRule = HostwrightNetworkPolicyRule(
            protocolName: .udp,
            port: 53,
            dns: "dns.example.test"
        )
        let first = try compile(
            policy: HostwrightServiceNetworkPolicy(
                ingress: [firstRule],
                egress: [secondRule]
            )
        )
        let second = try compile(
            policy: HostwrightServiceNetworkPolicy(
                ingress: [firstRule],
                egress: [secondRule]
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.dnsRules.count, 1)
        XCTAssertEqual(first.ingressRules.count, 1)
        XCTAssertEqual(first.forwardingRules.count, 2)
        XCTAssertEqual(first.providerRules.count, 2)
        XCTAssertEqual(first.tunnelRules.count, 0)
    }

    func testInvalidAndDuplicateRulesFailClosed() throws {
        XCTAssertNotNil(
            HostwrightNetworkPolicyValidation.issue(
                in: HostwrightNetworkPolicyRule()
            )
        )
        XCTAssertNotNil(
            HostwrightNetworkPolicyValidation.issue(
                in: HostwrightNetworkPolicyRule(
                    protocolName: nil,
                    port: 443
                )
            )
        )
        XCTAssertNotNil(
            HostwrightNetworkPolicyValidation.issue(
                in: HostwrightNetworkPolicyRule(
                    address: "10.20.0.1/24"
                )
            )
        )
        let duplicate = HostwrightNetworkPolicyRule(
            service: "web"
        )
        XCTAssertThrowsError(
            try compile(
                policy: HostwrightServiceNetworkPolicy(
                    ingress: [duplicate, duplicate]
                )
            )
        )
    }

    func testDecodedPlanRejectsTamperedDigest() throws {
        let plan = try compile(
            policy: HostwrightServiceNetworkPolicy(
                ingress: [
                    HostwrightNetworkPolicyRule(
                        service: "web",
                        protocolName: .tcp,
                        port: 8_080
                    )
                ]
            )
        )
        let data = try JSONEncoder().encode(plan)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
        object["sha256"] = String(repeating: "0", count: 64)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NetworkPolicyPlan.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkPolicyCompilerError,
                .invalidDigest
            )
        }
    }

    private func compile(
        policy: HostwrightServiceNetworkPolicy?,
        generation: Int = 1
    ) throws -> NetworkPolicyPlan {
        try NetworkPolicyCompiler.compile(
            projectName: "demo",
            projectUUID: projectUUID,
            generation: generation,
            services: [
                (
                    name: "api",
                    resourceUUID:
                        "22222222-2222-4222-8222-222222222222",
                    policy: policy
                )
            ]
        )
    }

    private func flow(
        direction: HostwrightNetworkPolicyDirection,
        sourceProject: String,
        sourceService: String,
        sourceIdentity: String? = nil,
        destinationProject: String = "demo",
        destinationService: String,
        destinationIdentity: String? = nil,
        address: String? = nil,
        port: Int? = nil,
        dns: String? = nil
    ) -> NetworkPolicyFlow {
        NetworkPolicyFlow(
            direction: direction,
            sourceProject: sourceProject,
            sourceService: sourceService,
            sourceIdentity: sourceIdentity,
            destinationProject: destinationProject,
            destinationService: destinationService,
            destinationIdentity: destinationIdentity,
            protocolName: .tcp,
            address: address,
            port: port,
            dns: dns
        )
    }

    private func replacing(
        _ value: NetworkPolicyFlow,
        sourceIdentity: String? = nil,
        address: String? = nil,
        port: Int? = nil,
        dns: String? = nil
    ) -> NetworkPolicyFlow {
        NetworkPolicyFlow(
            direction: value.direction,
            sourceProject: value.sourceProject,
            sourceService: value.sourceService,
            sourceIdentity: sourceIdentity ?? value.sourceIdentity,
            destinationProject: value.destinationProject,
            destinationService: value.destinationService,
            destinationIdentity: value.destinationIdentity,
            protocolName: value.protocolName,
            address: address ?? value.address,
            port: port ?? value.port,
            dns: dns ?? value.dns
        )
    }
}
