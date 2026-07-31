import XCTest
@testable import HostwrightCLI
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime

final class ProjectDNSPlanBuilderTests: XCTestCase {
    func testBuildPinsGuardedLoopbackHostAccessToOwnedGateway()
        throws
    {
        let projectUUID =
            "11111111-1111-4111-8111-111111111111"
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let attachment = try RuntimeDesiredNetworkAttachment(
            network: network
        )
        let service = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-0"
            ),
            image: "local/api:dev",
            hostAccess: [
                HostwrightHostAccessEndpoint(
                    hostname: "host-api.internal",
                    protocolName: .tcp,
                    addressClass: .loopback,
                    port: 6_508
                ),
            ],
            networks: [attachment]
        )
        let ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: network.resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            fencingToken:
                "22222222-2222-4222-8222-222222222222"
        )
        let inventory = try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS 26.0",
                architecture: "arm64",
                runtimeVersion: "1.1.0",
                services: []
            ),
            containers: [],
            images: [],
            networks: [
                RuntimeInventoryNetwork(
                    runtimeID: network.runtimeIdentifier,
                    name: network.runtimeIdentifier,
                    kind: "nat",
                    addresses: [
                        "192.168.64.0/24",
                        "192.168.64.1",
                    ],
                    labels: [
                        RuntimeInventoryLabel(
                            key:
                                RuntimeManagedResourceIdentity
                                    .managedLabel,
                            value: "true"
                        ),
                    ],
                    ownership: ownership
                ),
            ],
            volumes: []
        )

        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [service]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: []
            ),
            runtimeInventory: inventory
        )

        XCTAssertEqual(
            plan.hostAccessBindings,
            [
                ProjectDNSHostAccessBinding(
                    hostname: "host-api.internal",
                    protocolName: .tcp,
                    addressClass: .loopback,
                    listenAddress: "192.168.64.1",
                    clientCIDR: "192.168.64.0/24",
                    targetAddress: "127.0.0.1",
                    port: 6_508
                ),
            ]
        )
        XCTAssertTrue(
            plan.corefile.contains(
                "192.168.64.1 host-api.internal"
            )
        )
    }

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

    func testIngressUsesPersistedUUIDAndOnlyReadyReplicaBackends()
        throws
    {
        let projectUUID = "11111111-1111-4111-8111-111111111111"
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let ready = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let unhealthy = try desired(
            instance: "api-1",
            index: 1,
            network: network,
            aliases: []
        )
        let persistedUUID = "22222222-2222-4222-8222-222222222222"
        let binding = try LifecycleResourceBinding(
            identity: ready.identity,
            resourceIdentifier: ready.identity.managedResourceIdentifier,
            resourceUUID: persistedUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            currentFencingToken: "33333333-3333-4333-8333-333333333333"
        )
        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [unhealthy, ready]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    observed(
                        desired: unhealthy,
                        network: network,
                        address: "10.44.0.9",
                        health: .unhealthy
                    ),
                    observed(
                        desired: ready,
                        network: network,
                        address: "10.44.0.8",
                        health: .healthy
                    ),
                ]
            ),
            ingress: ingress(),
            projectID: "project-demo",
            resourceBindings: [binding]
        )

        let route = try XCTUnwrap(plan.ingressBindings.first?.routes.first)
        XCTAssertEqual(route.targetServiceName, "api")
        XCTAssertEqual(
            route.targetServiceUUIDs,
            [
                persistedUUID,
                HostwrightResourceUUID.legacy(
                    kind: "service",
                    identifier:
                        "project-demo:\(unhealthy.identity.displayName)"
                ),
            ].sorted()
        )
        XCTAssertEqual(
            route.backends,
            [
                ProjectIngressBackend(
                    serviceUUID: persistedUUID,
                    address: "10.44.0.8",
                    port: 8_080
                ),
            ]
        )
    }

    func testIngressFallsBackToLifecycleLegacyUUIDAndRetainsUnhealthyTarget()
        throws
    {
        let projectUUID = "11111111-1111-4111-8111-111111111111"
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let service = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let projectID = "project-demo"
        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                networks: [],
                services: [service]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [
                    observed(
                        desired: service,
                        network: network,
                        address: "10.44.0.8",
                        health: .unhealthy
                    ),
                ]
            ),
            ingress: ingress(),
            projectID: projectID
        )

        let route = try XCTUnwrap(plan.ingressBindings.first?.routes.first)
        XCTAssertEqual(route.targetServiceName, "api")
        XCTAssertEqual(
            route.targetServiceUUIDs,
            [
                HostwrightResourceUUID.legacy(
                    kind: "service",
                    identifier: "\(projectID):\(service.identity.displayName)"
                ),
            ]
        )
        XCTAssertTrue(route.backends.isEmpty)
    }

    func testLANIngressRequiresExactApprovedHostEnvironment() throws {
        let projectUUID =
            "11111111-1111-4111-8111-111111111111"
        let service = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-0"
            ),
            logicalServiceName: "api",
            image: "local/api:dev"
        )
        let exposure = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.1.0/24"],
            authentication: .tls
        )
        let listener = HostwrightIngressListener(
            bindAddress: "192.168.1.10",
            port: 8_443,
            exposure: exposure,
            certificate: "api-tls",
            routes: [
                HostwrightIngressRoute(
                    hostname: "api.example.test",
                    targetService: "api",
                    targetPort: 8_080
                ),
            ]
        )
        let environment = NetworkHostEnvironmentSnapshot(
            addresses: [
                NetworkHostInterfaceAddress(
                    interfaceName: "en0",
                    address: "192.168.1.10",
                    cidr: "192.168.1.0/24",
                    family: .ipv4,
                    networkClass: .privateLAN,
                    isLoopback: false
                ),
            ],
            primaryInterface: "en0",
            defaultRouter: "192.168.1.1",
            vpnState: .inactive,
            privateRelayState: .notObservable,
            localNetworkPermission: .notProbed
        )

        let plan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: DesiredRuntimeState(
                projectName: "demo",
                services: [service]
            ),
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: []
            ),
            certificates: [
                "api-tls": HostwrightCertificateDeclaration(
                    source: .localCA
                ),
            ],
            ingress: ["api": listener],
            projectID: "project-demo",
            hostEnvironment: environment
        )

        XCTAssertEqual(
            plan.ingressBindings.first?.exposure,
            exposure
        )
        XCTAssertEqual(
            plan.ingressBindings.first?.bindAddress,
            "192.168.1.10"
        )
    }

    func testLANIngressRejectsDeniedLocalNetworkPermission() {
        let service = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-0"
            ),
            logicalServiceName: "api",
            image: "local/api:dev"
        )
        let exposure = HostwrightPortExposurePolicy(
            scope: .lan,
            interfaces: ["en0"],
            networkClasses: [.privateLAN],
            allowedCIDRs: ["192.168.1.0/24"],
            authentication: .tls
        )
        let environment = NetworkHostEnvironmentSnapshot(
            addresses: [
                NetworkHostInterfaceAddress(
                    interfaceName: "en0",
                    address: "192.168.1.10",
                    cidr: "192.168.1.0/24",
                    family: .ipv4,
                    networkClass: .privateLAN,
                    isLoopback: false
                ),
            ],
            primaryInterface: "en0",
            defaultRouter: "192.168.1.1",
            vpnState: .inactive,
            privateRelayState: .inactive,
            localNetworkPermission: .denied
        )

        XCTAssertThrowsError(
            try ProjectDNSPlanBuilder.build(
                projectUUID:
                    "11111111-1111-4111-8111-111111111111",
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [service]
                ),
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: []
                ),
                certificates: [
                    "api-tls": HostwrightCertificateDeclaration(
                        source: .localCA
                    ),
                ],
                ingress: [
                    "api": HostwrightIngressListener(
                        bindAddress: "192.168.1.10",
                        port: 8_443,
                        exposure: exposure,
                        certificate: "api-tls",
                        routes: [
                            HostwrightIngressRoute(
                                hostname: "api.example.test",
                                targetService: "api",
                                targetPort: 8_080
                            ),
                        ]
                    ),
                ],
                projectID: "project-demo",
                hostEnvironment: environment
            )
        ) {
            XCTAssertTrue(
                String(describing: $0).contains(
                    NetworkExposureEnvironmentIssue
                        .localNetworkPermissionNotGranted.rawValue
                )
            )
        }
    }

    func testPublicAuthenticatedTunnelIngressRequiresDedicatedTunnelPath() {
        let service = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-0"
            ),
            logicalServiceName: "api",
            image: "local/api:dev"
        )
        let listener = HostwrightIngressListener(
            bindAddress: "203.0.113.10",
            port: 8_443,
            exposure: HostwrightPortExposurePolicy(
                scope: .public,
                interfaces: ["en0"],
                networkClasses: [.publicInternet],
                allowedCIDRs: ["203.0.113.0/24"],
                authentication: .authenticatedTunnel
            ),
            routes: [
                HostwrightIngressRoute(
                    hostname: "api.example.test",
                    targetService: "api",
                    targetPort: 8_080
                ),
            ]
        )

        XCTAssertThrowsError(
            try ProjectDNSPlanBuilder.build(
                projectUUID: "11111111-1111-4111-8111-111111111111",
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [service]
                ),
                observedState: ObservedRuntimeState(
                    projectName: "demo",
                    services: []
                ),
                ingress: ["api": listener],
                projectID: "project-demo"
            )
        ) {
            XCTAssertTrue(
                String(describing: $0).contains(
                    "requires scope 'tunnel' and its dedicated provider path"
                )
            )
        }
    }

    func testIngressPlanIsDeterministicAcrossInputOrdering()
        throws
    {
        let projectUUID = "11111111-1111-4111-8111-111111111111"
        let network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            projectUUID: projectUUID
        )
        let first = try desired(
            instance: "api-0",
            index: 0,
            network: network,
            aliases: []
        )
        let second = try desired(
            instance: "api-1",
            index: 1,
            network: network,
            aliases: []
        )
        let observedFirst = observed(
            desired: first,
            network: network,
            address: "10.44.0.8",
            health: .healthy
        )
        let observedSecond = observed(
            desired: second,
            network: network,
            address: "10.44.0.9",
            health: .healthy
        )
        let desiredState = DesiredRuntimeState(
            projectName: "demo",
            networks: [],
            services: [second, first]
        )
        let reversedState = DesiredRuntimeState(
            projectName: "demo",
            networks: [],
            services: [first, second]
        )
        let firstPlan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: desiredState,
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [observedSecond, observedFirst]
            ),
            ingress: ingress(),
            projectID: "project-demo"
        )
        let secondPlan = try ProjectDNSPlanBuilder.build(
            projectUUID: projectUUID,
            desiredState: reversedState,
            observedState: ObservedRuntimeState(
                projectName: "demo",
                services: [observedFirst, observedSecond]
            ),
            ingress: ingress(),
            projectID: "project-demo"
        )

        XCTAssertEqual(firstPlan.ingressBindings, secondPlan.ingressBindings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            try encoder.encode(firstPlan.ingressBindings),
            try encoder.encode(secondPlan.ingressBindings)
        )
    }

    func testNetworkPolicyPlanIsDeterministicAcrossReplicasAndGenerations()
        throws
    {
        let projectUUID =
            "11111111-1111-4111-8111-111111111111"
        let policy = HostwrightServiceNetworkPolicy(
            ingress: [
                HostwrightNetworkPolicyRule(
                    service: "gateway",
                    protocolName: .tcp,
                    port: 8_080
                )
            ],
            egress: [
                HostwrightNetworkPolicyRule(
                    protocolName: .tcp,
                    address: "10.42.0.0/24",
                    port: 443,
                    dns: "registry.example.test"
                )
            ]
        )
        let first = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-0"
            ),
            logicalServiceName: "api",
            replicaIndex: 0,
            image: "local/api:dev",
            networkPolicy: policy
        )
        let second = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-1"
            ),
            logicalServiceName: "api",
            replicaIndex: 1,
            image: "local/api:dev",
            networkPolicy: policy
        )
        let firstPlan = try XCTUnwrap(
            ProjectDNSPlanBuilder.networkPolicyPlan(
                projectUUID: projectUUID,
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [second, first]
                ),
                generation: 4
            )
        )
        let secondPlan = try XCTUnwrap(
            ProjectDNSPlanBuilder.networkPolicyPlan(
                projectUUID: projectUUID,
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [first, second]
                ),
                generation: 4
            )
        )

        XCTAssertEqual(firstPlan, secondPlan)
        XCTAssertEqual(firstPlan.services.count, 1)
        XCTAssertEqual(firstPlan.services[0].serviceName, "api")
        XCTAssertEqual(firstPlan.services[0].ingressDefault, .deny)
        XCTAssertEqual(firstPlan.services[0].egressDefault, .deny)
        XCTAssertEqual(firstPlan.generation, 4)
    }

    func testNetworkPolicyPlanRejectsReplicaPolicyDriftAndOmitsAbsentPolicy()
        throws
    {
        let projectUUID =
            "11111111-1111-4111-8111-111111111111"
        let absent = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            ),
            image: "local/api:dev"
        )
        XCTAssertNil(
            try ProjectDNSPlanBuilder.networkPolicyPlan(
                projectUUID: projectUUID,
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [absent]
                ),
                generation: 1
            )
        )
        let explicit = DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api",
                instanceName: "api-1"
            ),
            logicalServiceName: "api",
            replicaIndex: 1,
            image: "local/api:dev",
            networkPolicy: HostwrightServiceNetworkPolicy()
        )
        XCTAssertThrowsError(
            try ProjectDNSPlanBuilder.networkPolicyPlan(
                projectUUID: projectUUID,
                desiredState: DesiredRuntimeState(
                    projectName: "demo",
                    services: [absent, explicit]
                ),
                generation: 1
            )
        )
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

    private func ingress() -> [String: HostwrightIngressListener] {
        [
            "api": HostwrightIngressListener(
                port: 18_080,
                routes: [
                    HostwrightIngressRoute(
                        hostname: "api.local",
                        targetService: "api",
                        targetPort: 8_080
                    ),
                ]
            ),
        ]
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
