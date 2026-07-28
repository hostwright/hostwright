import XCTest
@testable import HostwrightNetworking

final class NetworkAddressPlannerTests: XCTestCase {
    func testPlansIPv4OnlyIPv6OnlyAndDualStackInCanonicalOrder() throws {
        let plans = try NetworkAddressPlanner.makePlans(
            definitions: [
                definition(
                    "v6",
                    ipv4: .disabled,
                    ipv6: .cidr("fd00:7:2::/64")
                ),
                definition(
                    "dual",
                    ipv4: .cidr("10.7.3.0/24"),
                    ipv6: .cidr("fd00:7:3::/64")
                ),
                definition(
                    "v4",
                    ipv4: .cidr("10.7.1.0/24"),
                    ipv6: .disabled
                )
            ],
            capabilities: .dualStack
        )

        XCTAssertEqual(plans.map(\.networkName), ["dual", "v4", "v6"])
        XCTAssertEqual(
            plans[0].families.map(\.family),
            [.ipv4, .ipv6]
        )
        XCTAssertEqual(
            plans[0].activeFamilies,
            [.ipv4, .ipv6]
        )
        XCTAssertEqual(plans[1].activeFamilies, [.ipv4])
        XCTAssertEqual(plans[2].activeFamilies, [.ipv6])
        XCTAssertEqual(plans[1].family(.ipv6)?.topology, .unavailable)
        XCTAssertEqual(plans[2].family(.ipv4)?.topology, .unavailable)
    }

    func testTopologyIsExplicitForNATAndHostOnlyPlans() throws {
        let plans = try NetworkAddressPlanner.makePlans(
            definitions: [
                definition(
                    "internal",
                    driver: .hostOnly,
                    ipv4: .cidr("10.8.0.0/24"),
                    ipv6: .disabled
                ),
                definition(
                    "nat",
                    ipv4: .cidr("10.9.0.0/24"),
                    ipv6: .disabled
                )
            ],
            capabilities: .dualStack
        )

        XCTAssertEqual(plans[0].family(.ipv4)?.topology, .hostOnly)
        XCTAssertEqual(plans[1].family(.ipv4)?.topology, .nat)
    }

    func testUnavailableRequestedFamilyReturnsStablePreMutationResult() throws {
        let result = try NetworkAddressPlanner.evaluate(
            definitions: [
                definition(
                    "v6-only",
                    ipv4: .disabled,
                    ipv6: .cidr("fd00:7::/64")
                )
            ],
            capabilities: NetworkAddressCapabilities(
                ipv4: .fullyAvailable,
                ipv6: .unavailable(
                    reason: "Provider has no qualified IPv6 network support."
                )
            )
        )

        XCTAssertEqual(
            result,
            .unavailable(
                NetworkAddressUnavailable(
                    networkName: "v6-only",
                    family: .ipv6,
                    requestedMode: .cidr,
                    reason: "Provider has no qualified IPv6 network support."
                )
            )
        )
    }

    func testProviderThatCannotDisableFamilyRejectsSingleStackPlan() throws {
        let result = try NetworkAddressPlanner.evaluate(
            definitions: [
                definition(
                    "v4-only",
                    ipv4: .auto,
                    ipv6: .disabled
                )
            ],
            capabilities: NetworkAddressCapabilities(
                ipv4: .fullyAvailable,
                ipv6: NetworkAddressFamilyCapability(
                    automatic: true,
                    explicitCIDR: true,
                    disabled: false,
                    unavailableReason: "Provider always enables IPv6."
                )
            )
        )

        XCTAssertEqual(
            result,
            .unavailable(
                NetworkAddressUnavailable(
                    networkName: "v4-only",
                    family: .ipv6,
                    requestedMode: .disabled,
                    reason: "Provider always enables IPv6."
                )
            )
        )
    }

    func testBothFamiliesDisabledAndDuplicateNamesFailClosed() {
        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "empty",
                        ipv4: .disabled,
                        ipv6: .disabled
                    )
                ],
                capabilities: .dualStack
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .allFamiliesDisabled(networkName: "empty")
            )
        }

        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition("duplicate", ipv6: .disabled),
                    definition("duplicate", ipv6: .disabled)
                ],
                capabilities: .dualStack
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .duplicateNetworkName("duplicate")
            )
        }
    }

    func testInvalidPrefixesFamiliesAndHostBitsFailClosed() {
        assertPlanningFails(
            ipv4: .cidr("10.0.0.0/31"),
            ipv6: .disabled,
            expected: .invalidPrefix(family: .ipv4, value: 31)
        )
        assertPlanningFails(
            ipv4: .disabled,
            ipv6: .cidr("fd00::/127"),
            expected: .invalidPrefix(family: .ipv6, value: 127)
        )
        assertPlanningFails(
            ipv4: .cidr("10.0.0.1/24"),
            ipv6: .disabled,
            expected: .hostBitsSet(
                family: .ipv4,
                value: "10.0.0.1/24"
            )
        )
        assertPlanningFails(
            ipv4: .cidr("fd00::/64"),
            ipv6: .disabled,
            expected: .invalidCIDR(
                family: .ipv4,
                value: "fd00::"
            )
        )
    }

    func testReservedNetworkRangesFailClosed() {
        assertPlanningFails(
            ipv4: .cidr("127.42.0.0/16"),
            ipv6: .disabled,
            expected: .reservedRange(
                family: .ipv4,
                value: "127.42.0.0/16",
                reserved: "127.0.0.0/8"
            )
        )
        assertPlanningFails(
            ipv4: .disabled,
            ipv6: .cidr("fe80::/64"),
            expected: .reservedRange(
                family: .ipv6,
                value: "fe80::/64",
                reserved: "fe80::/10"
            )
        )
    }

    func testExplicitNetworksRejectPeerHostAndOccupiedOverlap() {
        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "a",
                        ipv4: .cidr("10.10.0.0/24"),
                        ipv6: .disabled
                    ),
                    definition(
                        "b",
                        ipv4: .cidr("10.10.0.128/25"),
                        ipv6: .disabled
                    )
                ],
                capabilities: .dualStack
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .networkOverlap(
                    first: "10.10.0.0/24",
                    second: "10.10.0.128/25"
                )
            )
        }

        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "host-conflict",
                        ipv4: .cidr("10.11.0.0/24"),
                        ipv6: .disabled
                    )
                ],
                capabilities: .dualStack,
                constraints: NetworkAddressPlanningConstraints(
                    hostCIDRs: ["10.11.0.23/32"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .hostConflict(
                    network: "10.11.0.0/24",
                    host: "10.11.0.23/32"
                )
            )
        }

        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "occupied-conflict",
                        ipv4: .disabled,
                        ipv6: .cidr("fd00:12::/64")
                    )
                ],
                capabilities: .dualStack,
                constraints: NetworkAddressPlanningConstraints(
                    occupiedCIDRs: ["fd00:12::1/80"]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .occupiedConflict(
                    network: "fd00:12::/64",
                    occupied: "fd00:12::/80"
                )
            )
        }
    }

    func testObservationReportsMissingFamilyWithoutFabricatingIt() throws {
        let plan = try XCTUnwrap(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "dual",
                        ipv4: .cidr("10.13.0.0/24"),
                        ipv6: .cidr("fd00:13::/64")
                    )
                ],
                capabilities: .dualStack
            ).first
        )

        let report = try NetworkAddressObserver.verify(
            plan: plan,
            observed: [
                NetworkAddressFamilyObservation(
                    family: .ipv4,
                    topology: .nat,
                    cidr: "10.13.0.0/24",
                    gateway: "10.13.0.1",
                    assignedAddresses: ["10.13.0.3/24"]
                )
            ]
        )

        XCTAssertEqual(report.family(.ipv4)?.state, .available)
        XCTAssertTrue(report.canPublishListener(for: .ipv4))
        XCTAssertEqual(report.family(.ipv6)?.state, .unavailable)
        XCTAssertEqual(report.family(.ipv6)?.topology, .unavailable)
        XCTAssertNil(report.family(.ipv6)?.cidr)
        XCTAssertFalse(report.canPublishListener(for: .ipv6))
    }

    func testIPv6ListenerRequiresAnActuallyAssignedIPv6Address() throws {
        let plan = try XCTUnwrap(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "v6",
                        ipv4: .disabled,
                        ipv6: .cidr("fd00:14::/64")
                    )
                ],
                capabilities: .dualStack
            ).first
        )

        let withoutAddress = try NetworkAddressObserver.verify(
            plan: plan,
            observed: [
                NetworkAddressFamilyObservation(
                    family: .ipv6,
                    topology: .routed,
                    cidr: "fd00:14::/64",
                    gateway: "fd00:14::1"
                )
            ]
        )
        XCTAssertEqual(withoutAddress.family(.ipv6)?.topology, .routed)
        XCTAssertFalse(withoutAddress.canPublishListener(for: .ipv6))

        let withAddress = try NetworkAddressObserver.verify(
            plan: plan,
            observed: [
                NetworkAddressFamilyObservation(
                    family: .ipv6,
                    topology: .routed,
                    cidr: "fd00:14::/64",
                    gateway: "fd00:14::1",
                    assignedAddresses: ["FD00:14:0:0:0:0:0:3/64"]
                )
            ]
        )
        XCTAssertEqual(
            withAddress.family(.ipv6)?.assignedAddresses,
            ["fd00:14::3"]
        )
        XCTAssertTrue(withAddress.canPublishListener(for: .ipv6))
    }

    func testObservationNormalizesProviderInterfaceCIDRToSubnetAndGateway()
        throws
    {
        let plan = try XCTUnwrap(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "dual",
                        ipv4: .cidr("10.14.0.0/24"),
                        ipv6: .cidr("fd42:7:5::/64")
                    )
                ],
                capabilities: .dualStack
            ).first
        )

        let report = try NetworkAddressObserver.verify(
            plan: plan,
            observed: [
                NetworkAddressFamilyObservation(
                    family: .ipv4,
                    topology: .nat,
                    cidr: "10.14.0.0/24",
                    gateway: "10.14.0.1"
                ),
                NetworkAddressFamilyObservation(
                    family: .ipv6,
                    topology: .nat,
                    cidr: "fd42:7:5::1/64"
                ),
            ]
        )

        XCTAssertEqual(report.family(.ipv6)?.cidr, "fd42:7:5::/64")
        XCTAssertEqual(report.family(.ipv6)?.gateway, "fd42:7:5::1")
        XCTAssertFalse(report.canPublishListener(for: .ipv6))
    }

    func testObservationRejectsUnexpectedFamilyCIDRMismatchAndInvalidGateway() throws {
        let plan = try XCTUnwrap(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "v4",
                        ipv4: .cidr("10.15.0.0/24"),
                        ipv6: .disabled
                    )
                ],
                capabilities: .dualStack
            ).first
        )

        XCTAssertThrowsError(
            try NetworkAddressObserver.verify(
                plan: plan,
                observed: [
                    NetworkAddressFamilyObservation(
                        family: .ipv6,
                        topology: .nat,
                        cidr: "fd00:15::/64"
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try NetworkAddressObserver.verify(
                plan: plan,
                observed: [
                    NetworkAddressFamilyObservation(
                        family: .ipv4,
                        topology: .nat,
                        cidr: "10.16.0.0/24"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .observedCIDRMismatch(
                    networkName: "v4",
                    family: .ipv4,
                    expected: "10.15.0.0/24",
                    actual: "10.16.0.0/24"
                )
            )
        }
        XCTAssertThrowsError(
            try NetworkAddressObserver.verify(
                plan: plan,
                observed: [
                    NetworkAddressFamilyObservation(
                        family: .ipv4,
                        topology: .nat,
                        cidr: "10.15.0.0/24",
                        gateway: "10.15.1.1"
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                .invalidGateway(
                    networkName: "v4",
                    family: .ipv4,
                    value: "10.15.1.1"
                )
            )
        }
    }

    func testObservationCanonicalizesAndSortsOnlyObservedAddresses() throws {
        let plan = try XCTUnwrap(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "dual",
                        ipv4: .cidr("10.16.0.0/24"),
                        ipv6: .cidr("fd00:16::/64")
                    )
                ],
                capabilities: .dualStack
            ).first
        )

        let report = try NetworkAddressObserver.verify(
            plan: plan,
            observed: [
                NetworkAddressFamilyObservation(
                    family: .ipv6,
                    topology: .hostOnly,
                    cidr: "fd00:16::/64",
                    assignedAddresses: ["fd00:16::9", "fd00:16::2"]
                ),
                NetworkAddressFamilyObservation(
                    family: .ipv4,
                    topology: .nat,
                    cidr: "10.16.0.0/24",
                    assignedAddresses: [
                        "10.16.0.9/24",
                        "10.16.0.2",
                        "10.16.0.2"
                    ]
                )
            ]
        )

        XCTAssertEqual(report.families.map(\.family), [.ipv4, .ipv6])
        XCTAssertEqual(
            report.family(.ipv4)?.assignedAddresses,
            ["10.16.0.2", "10.16.0.9"]
        )
        XCTAssertEqual(
            report.family(.ipv6)?.assignedAddresses,
            ["fd00:16::2", "fd00:16::9"]
        )
    }

    func testHappyEyeballsCandidatesAreCanonicalDeterministicAndIPv6First() throws {
        let first = try NetworkHappyEyeballsPlanner.candidates(
            ipv4Addresses: ["10.0.0.9", "10.0.0.2", "10.0.0.2"],
            ipv6Addresses: ["fd00::9", "FD00:0:0:0:0:0:0:2"]
        )
        let second = try NetworkHappyEyeballsPlanner.candidates(
            ipv4Addresses: ["10.0.0.2", "10.0.0.9"],
            ipv6Addresses: ["fd00::2", "fd00::9"]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.map(\.family),
            [.ipv6, .ipv4, .ipv6, .ipv4]
        )
        XCTAssertEqual(
            first.map(\.address),
            ["fd00::2", "10.0.0.2", "fd00::9", "10.0.0.9"]
        )
        XCTAssertEqual(
            first.map(\.startDelayMilliseconds),
            [0, 250, 500, 750]
        )
    }

    func testHostInterfaceInventoryProducesCanonicalPlannerConstraints()
        throws
    {
        let cidrs = try NetworkHostInterfaceInventory.currentCIDRs()
        XCTAssertEqual(cidrs, Array(Set(cidrs)).sorted())
        XCTAssertTrue(cidrs.allSatisfy { $0.contains("/") })

        _ = try NetworkAddressPlanner.makePlans(
            definitions: [definition("automatic")],
            capabilities: .dualStack,
            constraints: NetworkAddressPlanningConstraints(
                hostCIDRs: cidrs
            )
        )
    }

    private func definition(
        _ name: String,
        driver: HostwrightNetworkDriver = .nat,
        ipv4: HostwrightNetworkAddressRequest = .auto,
        ipv6: HostwrightNetworkAddressRequest = .auto
    ) -> HostwrightNetworkDefinition {
        HostwrightNetworkDefinition(
            name: name,
            driver: driver,
            ipv4: ipv4,
            ipv6: ipv6
        )
    }

    private func assertPlanningFails(
        ipv4: HostwrightNetworkAddressRequest,
        ipv6: HostwrightNetworkAddressRequest,
        expected: NetworkAddressPlanningError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NetworkAddressPlanner.makePlans(
                definitions: [
                    definition(
                        "network",
                        ipv4: ipv4,
                        ipv6: ipv6
                    )
                ],
                capabilities: .dualStack
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? NetworkAddressPlanningError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
