import XCTest
@testable import HostwrightCLI
import HostwrightNetworking
import HostwrightRuntime

final class ProjectDNSPlanBuilderTests: XCTestCase {
    func testBuildPublishesOnlyReadyObservedAddressesAndAliases()
        throws
    {
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "11111111-1111-1111-1111-111111111111"
        )
        let ready = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: ["backend"]
        )
        let unready = try desired(
            instance: "api-1",
            index: 1,
            network: network,
            aliases: ["backend"]
        )
        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID:
                "11111111-1111-1111-1111-111111111111",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [unready, ready]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    observed(
                        desired: ready,
                        network: network,
                        address: "10.44.0.8",
                        health: .healthy
                    ),
                    observed(
                        desired: unready,
                        network: network,
                        address: "10.44.0.9",
                        health: .unhealthy
                    )
                ]
            )
        )

        XCTAssertTrue(
            plan.records.contains {
                $0.name == "api.\(plan.zone)." &&
                    $0.address == "10.44.0.8"
            }
        )
        XCTAssertTrue(
            plan.records.contains {
                $0.name == "backend.\(plan.zone)." &&
                    $0.address == "10.44.0.8"
            }
        )
        XCTAssertFalse(
            plan.records.contains { $0.address == "10.44.0.9" }
        )
    }

    func testRunningServiceWithoutReadinessProbeIsReady()
        throws
    {
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "11111111-1111-1111-1111-111111111111"
        )
        let desired = try desired(
            instance: "worker-0",
            index: 0,
            network: network,
            aliases: []
        )
        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID:
                "11111111-1111-1111-1111-111111111111",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [desired]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    observed(
                        desired: desired,
                        network: network,
                        address: "10.44.0.10",
                        health: .notConfigured
                    )
                ]
            )
        )

        XCTAssertEqual(
            Set(plan.records.map(\.address)),
            ["10.44.0.10"]
        )

        let providerWithoutHealth = try ProjectDNSPlanBuilder.build(
            projectUUID:
                "11111111-1111-1111-1111-111111111111",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [desired]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    observed(
                        desired: desired,
                        network: network,
                        address: "10.44.0.10/24",
                        health: .unknown
                    )
                ]
            )
        )
        XCTAssertEqual(
            Set(providerWithoutHealth.records.map(\.address)),
            ["10.44.0.10"]
        )
    }

    func testBuildNormalizesObservedCIDRAddressesToDNSHosts()
        throws
    {
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "11111111-1111-1111-1111-111111111111"
        )
        let desired = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let observed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier:
                desired.identity.managedResourceIdentifier,
            lifecycleState: .running,
            healthState: .healthy,
            networks: [
                RuntimeNetworkAttachment(
                    name: network.runtimeIdentifier,
                    ipv4Address: "10.44.0.8/24",
                    ipv6Address: "fd00:44::8/64"
                )
            ]
        )

        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID:
                "11111111-1111-1111-1111-111111111111",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [desired]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [observed]
            )
        )

        XCTAssertEqual(
            Set(plan.records.map(\.address)),
            ["10.44.0.8", "fd00:44::8"]
        )
    }

    func testBuildRejectsMalformedObservedCIDRPrefix()
        throws
    {
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "11111111-1111-1111-1111-111111111111"
        )
        let desired = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let malformed = ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier:
                desired.identity.managedResourceIdentifier,
            lifecycleState: .running,
            healthState: .healthy,
            networks: [
                RuntimeNetworkAttachment(
                    name: network.runtimeIdentifier,
                    ipv4Address: "10.44.0.8/not-a-prefix"
                )
            ]
        )

        XCTAssertThrowsError(
            try ProjectDNSPlanBuilder.build(
                projectUUID:
                    "11111111-1111-1111-1111-111111111111",
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    networks: [],
                    services: [desired]
                ),
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: [malformed]
                )
            )
        )
    }

    func testUnknownOrUnattachedRuntimeAddressesAreNotPublished()
        throws
    {
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID:
                "11111111-1111-1111-1111-111111111111"
        )
        let desired = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID:
                "11111111-1111-1111-1111-111111111111",
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [desired]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    ObservedRuntimeService(
                        identity: desired.identity,
                        resourceIdentifier:
                            desired.identity
                                .managedResourceIdentifier,
                        lifecycleState: .running,
                        healthState: .healthy,
                        networks: [
                            RuntimeNetworkAttachment(
                                name: "unmanaged",
                                ipv4Address: "10.99.0.2"
                            )
                        ]
                    )
                ]
            )
        )

        XCTAssertTrue(plan.records.isEmpty)
    }

    private func desired(
        instance: String,
        index: Int,
        network: RuntimeNetworkIdentity,
        aliases: [String]
    ) throws -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: instance
            ),
            logicalServiceName: "api",
            replicaIndex: index,
            image: "local/api:dev",
            networks: [
                try RuntimeDesiredNetworkAttachment(
                    network: network,
                    aliases: aliases
                )
            ]
        )
    }

    private func observed(
        desired: DesiredRuntimeService,
        network: RuntimeNetworkIdentity,
        address: String,
        health: RuntimeHealthState
    ) -> ObservedRuntimeService {
        ObservedRuntimeService(
            identity: desired.identity,
            resourceIdentifier:
                desired.identity.managedResourceIdentifier,
            lifecycleState: .running,
            healthState: health,
            networks: [
                RuntimeNetworkAttachment(
                    name: network.runtimeIdentifier,
                    ipv4Address: address
                )
            ]
        )
    }
}
