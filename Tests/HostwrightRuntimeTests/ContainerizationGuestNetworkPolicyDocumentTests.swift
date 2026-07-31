import HostwrightNetworking
import XCTest
@testable import HostwrightRuntime

final class ContainerizationGuestNetworkPolicyDocumentTests: XCTestCase {
    func testDigestMatchesLanguageNeutralCanonicalContract() throws {
        let policy = try fixture()

        XCTAssertEqual(
            policy.sha256,
            "11648e11c0396db47980bdefbb677cdbe37b4e56513fd0e8c16c8e13d71c3c7f"
        )
    }

    func testApplyWireDocumentCarriesBoundIdentityDefaultsAndBootstrapSettings()
        throws
    {
        let policy = try fixture()
        let request = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: policy,
            targetUID: 1_000,
            targetGID: 1_001,
            workingDirectory: "/srv/app"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encoded())
                as? [String: Any]
        )

        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["operation"] as? String, "apply")
        XCTAssertEqual(object["policyDigest"] as? String, policy.sha256)
        XCTAssertEqual(
            object["projectUUID"] as? String,
            "22222222-2222-4222-8222-222222222222"
        )
        XCTAssertEqual(
            object["serviceResourceUUID"] as? String,
            "11111111-1111-4111-8111-111111111111"
        )
        XCTAssertEqual(object["ingressDefault"] as? String, "deny")
        XCTAssertEqual(object["egressDefault"] as? String, "deny")
        XCTAssertEqual(object["targetUID"] as? Int, 1_000)
        XCTAssertEqual(object["targetGID"] as? Int, 1_001)
        XCTAssertEqual(object["workingDirectory"] as? String, "/srv/app")

        let ingress = try XCTUnwrap(
            object["ingress"] as? [[String: Any]]
        )
        XCTAssertEqual(ingress[0]["cidr"] as? String, "10.0.0.0/24")
        XCTAssertEqual(ingress[0]["protocol"] as? String, "tcp")
        XCTAssertEqual(ingress[0]["destinationPort"] as? Int, 443)

        let egress = try XCTUnwrap(
            object["egress"] as? [[String: Any]]
        )
        XCTAssertEqual(egress[0]["cidr"] as? String, "2001:db8::/64")
        XCTAssertEqual(egress[0]["protocol"] as? String, "udp")
        XCTAssertNil(egress[0]["destinationPort"])
    }

    func testVerifyWireDocumentCarriesDigestInputsWithoutBootstrapSettings()
        throws
    {
        let policy = try fixture()
        let request = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .verify,
            policy: policy,
            targetUID: 1_000,
            targetGID: 1_001,
            workingDirectory: "/srv/app"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.encoded())
                as? [String: Any]
        )

        XCTAssertEqual((object["ingress"] as? [Any])?.count, 1)
        XCTAssertEqual((object["egress"] as? [Any])?.count, 1)
        XCTAssertEqual((object["dnsServers"] as? [Any])?.count, 1)
        XCTAssertNil(object["targetUID"])
        XCTAssertNil(object["targetGID"])
        XCTAssertNil(object["workingDirectory"])
    }

    func testDecodeRejectsDigestTampering() throws {
        let policy = try fixture()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: policy.encoded())
                as? [String: Any]
        )
        object["sha256"] = String(repeating: "0", count: 64)
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ContainerizationGuestNetworkPolicy.self,
                from: data
            )
        ) { error in
            XCTAssertEqual(
                error as? ContainerizationGuestNetworkPolicyError,
                .invalidDigest
            )
        }
    }

    private func fixture() throws -> ContainerizationGuestNetworkPolicy {
        try ContainerizationGuestNetworkPolicy(
            generation: 7,
            projectUUID: "22222222-2222-4222-8222-222222222222",
            serviceResourceUUID: "11111111-1111-4111-8111-111111111111",
            ingressDefault: .deny,
            egressDefault: .deny,
            dnsServers: ["1.1.1.1"],
            ingress: [
                try ContainerizationGuestNetworkPolicyRule(
                    address: "10.0.0.0/24",
                    port: 443,
                    protocolName: .tcp
                )
            ],
            egress: [
                try ContainerizationGuestNetworkPolicyRule(
                    address: "2001:db8::/64",
                    protocolName: .udp
                )
            ]
        )
    }
}
