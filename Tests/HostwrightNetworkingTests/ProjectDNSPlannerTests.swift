import XCTest
@testable import HostwrightNetworking

final class ProjectDNSPlannerTests: XCTestCase {
    private let projectUUID = "11111111-1111-1111-1111-111111111111"

    func testReadyReplicasPublishServiceReplicaAndAliasRecords() throws {
        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [
                ProjectDNSService(
                    name: "api",
                    aliases: ["backend"],
                    replicas: [
                        ProjectDNSReplica(
                            name: "api-0",
                            isReady: true,
                            ipv4Addresses: ["10.0.0.3"],
                            ipv6Addresses: ["fd00::3"]
                        ),
                        ProjectDNSReplica(
                            name: "api-1",
                            isReady: false,
                            ipv4Addresses: ["10.0.0.4"],
                            ipv6Addresses: ["fd00::4"]
                        )
                    ]
                )
            ]
        )

        XCTAssertEqual(
            plan.zone,
            "11111111-1111-1111-1111-111111111111.hostwright.internal"
        )
        XCTAssertEqual(plan.records.count, 6)
        XCTAssertEqual(Set(plan.records.map(\.address)), ["10.0.0.3", "fd00::3"])
        XCTAssertEqual(
            Set(plan.records.map(\.name)),
            [
                "api.\(plan.zone).",
                "api-0.api.\(plan.zone).",
                "backend.\(plan.zone)."
            ]
        )
        XCTAssertFalse(plan.corefile.contains("10.0.0.4"))
        XCTAssertFalse(plan.corefile.contains("fd00::4"))
    }

    func testPlanIsDeterministicAcrossInputOrderingAndDuplicateAddresses() throws {
        let first = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID.uppercased(),
            services: [
                service(
                    "web",
                    alias: "frontend",
                    replica: "web-0",
                    ipv4: ["10.0.0.2", "10.0.0.2"],
                    ipv6: ["FD00:0:0:0:0:0:0:2"]
                ),
                service(
                    "api",
                    alias: "backend",
                    replica: "api-0",
                    ipv4: ["10.0.0.3"],
                    ipv6: ["fd00::3"]
                )
            ],
            options: ProjectDNSOptions(
                upstreams: ["2001:4860:4860::8888", "1.1.1.1", "1.1.1.1"],
                searchDomains: ["svc.example", "corp.example"]
            )
        )
        let second = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [
                service(
                    "api",
                    alias: "backend",
                    replica: "api-0",
                    ipv4: ["10.0.0.3"],
                    ipv6: ["fd00::3"]
                ),
                service(
                    "web",
                    alias: "frontend",
                    replica: "web-0",
                    ipv4: ["10.0.0.2"],
                    ipv6: ["fd00::2"]
                )
            ],
            options: ProjectDNSOptions(
                upstreams: ["1.1.1.1", "2001:4860:4860::8888"],
                searchDomains: ["corp.example", "svc.example"]
            )
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.projectUUID, projectUUID)
        XCTAssertEqual(first.upstreams, ["1.1.1.1", "2001:4860:4860::8888"])
        XCTAssertEqual(
            first.searchDomains,
            [first.zone, "corp.example", "svc.example"]
        )
        XCTAssertEqual(
            first.searchDirective,
            "search \(first.zone) corp.example svc.example"
        )
    }

    func testRecordsHaveStableNameTypeAddressOrdering() throws {
        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [
                service(
                    "api",
                    alias: "backend",
                    replica: "api-0",
                    ipv4: ["10.0.0.9", "10.0.0.2"],
                    ipv6: ["fd00::9", "fd00::2"]
                )
            ]
        )

        XCTAssertEqual(
            plan.records.map(\.name),
            plan.records.map(\.name).sorted()
        )
        for name in Set(plan.records.map(\.name)) {
            XCTAssertEqual(
                plan.records.filter { $0.name == name }.map(\.type),
                [.a, .a, .aaaa, .aaaa]
            )
        }
        XCTAssertEqual(plan.records.map(\.ttlSeconds), Array(repeating: 30, count: 12))
    }

    func testCorefileRendersBoundedCacheAndSortedUpstreams() throws {
        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [],
            options: ProjectDNSOptions(
                ttlSeconds: 45,
                negativeTTLSeconds: 7,
                upstreams: ["9.9.9.9", "1.1.1.1"]
            )
        )

        XCTAssertTrue(plan.corefile.contains("ttl 45"))
        XCTAssertTrue(plan.corefile.contains("success 1024 45 0"))
        XCTAssertTrue(plan.corefile.contains("denial 1024 7 0"))
        XCTAssertTrue(plan.corefile.contains("forward . 1.1.1.1 9.9.9.9"))
        XCTAssertTrue(plan.corefile.contains("hosts /dev/null \(plan.zone)"))
        XCTAssertTrue(plan.corefile.contains("reload 2s"))
        XCTAssertTrue(plan.corefile.contains("reload 0s"))
        XCTAssertTrue(plan.corefile.hasSuffix("\n"))
    }

    func testCorefileUsesContainerResolverWhenNoExplicitUpstreamExists() throws {
        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: []
        )

        XCTAssertTrue(
            plan.corefile.contains("forward . /etc/resolv.conf")
        )
    }

    func testTTLAndCollectionBoundsFailClosed() {
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: [],
                options: ProjectDNSOptions(ttlSeconds: 0)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectDNSPlanningError,
                .invalidTTL(kind: "positive", value: 0, range: 1...300)
            )
        }
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: [],
                options: ProjectDNSOptions(negativeTTLSeconds: 61)
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectDNSPlanningError,
                .invalidTTL(kind: "negative", value: 61, range: 1...60)
            )
        }
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: [],
                options: ProjectDNSOptions(
                    upstreams: Array(repeating: "1.1.1.1", count: 9)
                )
            )
        )
    }

    func testInvalidNamesAddressesAndDomainsFailClosed() {
        assertPlanningError(
            services: [service("API", alias: "backend", replica: "api-0")],
            matches: .invalidName(kind: "service", value: "API")
        )
        assertPlanningError(
            services: [service("api", alias: "bad_alias", replica: "api-0")],
            matches: .invalidName(kind: "alias", value: "bad_alias")
        )
        assertPlanningError(
            services: [service("api", alias: "backend", replica: "Api-0")],
            matches: .invalidName(kind: "replica", value: "Api-0")
        )
        assertPlanningError(
            services: [
                service(
                    "api",
                    alias: "backend",
                    replica: "api-0",
                    ipv4: ["010.0.0.1"]
                )
            ],
            matches: .invalidAddress(family: "A", value: "010.0.0.1")
        )
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: [],
                options: ProjectDNSOptions(searchDomains: ["Corp.Example"])
            )
        )
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: [],
                options: ProjectDNSOptions(upstreams: ["dns.example"])
            )
        )
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: "not-a-uuid",
                services: []
            )
        )
    }

    func testDuplicateAndConflictingNamesFailClosed() {
        assertPlanningError(
            services: [
                service("api", alias: "backend", replica: "api-0"),
                service("api", alias: "other", replica: "api-1")
            ],
            matches: .duplicateName(kind: "service", value: "api")
        )
        assertPlanningError(
            services: [
                ProjectDNSService(
                    name: "api",
                    replicas: [
                        ProjectDNSReplica(name: "api-0", isReady: true),
                        ProjectDNSReplica(name: "api-0", isReady: true)
                    ]
                )
            ],
            matches: .duplicateName(
                kind: "replica in service 'api'",
                value: "api-0"
            )
        )
        assertPlanningError(
            services: [
                service("api", alias: "shared", replica: "api-0"),
                service("web", alias: "shared", replica: "web-0")
            ],
            matches: .nameConflict(
                name: "shared",
                firstOwner: "alias:api",
                secondOwner: "alias:web"
            )
        )
        assertPlanningError(
            services: [
                service("api", alias: "web", replica: "api-0"),
                service("web", alias: "frontend", replica: "web-0")
            ],
            matches: .nameConflict(
                name: "web",
                firstOwner: "service:web",
                secondOwner: "alias:api"
            )
        )
    }

    func testPlanRoundTripsThroughCodableWithoutChangingRenderedOutput() throws {
        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [
                service(
                    "api",
                    alias: "backend",
                    replica: "api-0",
                    ipv4: ["10.0.0.3"],
                    ipv6: ["fd00::3"]
                )
            ],
            options: ProjectDNSOptions(
                ttlSeconds: 20,
                negativeTTLSeconds: 4,
                upstreams: ["1.1.1.1"],
                searchDomains: ["corp.example"]
            )
        )

        let encoded = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(ProjectDNSPlan.self, from: encoded), plan)
    }

    func testHostAccessAllowsMultipleDeclaredPortsForOneBrokerHostname()
        throws
    {
        let first = ProjectDNSHostAccessBinding(
            hostname: "host-api.internal",
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: "192.168.64.1",
            clientCIDR: "192.168.64.0/24",
            targetAddress: "127.0.0.1",
            port: 6_508
        )
        let second = ProjectDNSHostAccessBinding(
            hostname: first.hostname,
            protocolName: .tcp,
            addressClass: .loopback,
            listenAddress: first.listenAddress,
            clientCIDR: first.clientCIDR,
            targetAddress: first.targetAddress,
            port: 6_509
        )

        let plan = try ProjectDNSPlanner.makePlan(
            projectUUID: projectUUID,
            services: [],
            hostAccessBindings: [second, first]
        )

        XCTAssertEqual(plan.hostAccessBindings, [first, second])
        XCTAssertEqual(
            plan.corefile.components(
                separatedBy:
                    "        192.168.64.1 host-api.internal"
            ).count - 1,
            1
        )
    }

    private func service(
        _ name: String,
        alias: String,
        replica: String,
        ipv4: [String] = [],
        ipv6: [String] = []
    ) -> ProjectDNSService {
        ProjectDNSService(
            name: name,
            aliases: [alias],
            replicas: [
                ProjectDNSReplica(
                    name: replica,
                    isReady: true,
                    ipv4Addresses: ipv4,
                    ipv6Addresses: ipv6
                )
            ]
        )
    }

    private func assertPlanningError(
        services: [ProjectDNSService],
        matches expected: ProjectDNSPlanningError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ProjectDNSPlanner.makePlan(
                projectUUID: projectUUID,
                services: services
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ProjectDNSPlanningError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
