import Foundation
import XCTest
@testable import HostwrightRuntime

final class RuntimeInventoryTests: XCTestCase {
    func testCompleteInventoryIsTypedSortedAndSemanticallyRepeatable() throws {
        let containerB = makeContainer(
            runtimeID: "container-b",
            name: "worker",
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            lifecycle: .stopped
        )
        let containerA = makeContainer(
            runtimeID: "container-a",
            name: "api",
            resourceUUID: "33333333-3333-4333-8333-333333333333",
            lifecycle: .running
        )
        let image = RuntimeInventoryImage(
            runtimeID: "image-a",
            descriptorDigest: digest("a"),
            references: ["registry.example/api:latest", "registry.example/api@" + digest("a")],
            variants: [
                RuntimeInventoryImageVariant(
                    digest: digest("c"),
                    architecture: "arm64",
                    operatingSystem: "linux"
                ),
                RuntimeInventoryImageVariant(
                    digest: digest("b"),
                    architecture: "amd64",
                    operatingSystem: "linux"
                )
            ],
            labels: [RuntimeInventoryLabel(key: "org.example.kind", value: "application")]
        )
        let network = RuntimeInventoryNetwork(
            runtimeID: "network-a",
            name: "default",
            kind: "vmnet",
            addresses: ["fd00::1", "192.168.64.1"],
            labels: [
                RuntimeInventoryLabel(
                    key: RuntimeManagedResourceIdentity.managedLabel,
                    value: "true"
                )
            ],
            ownership: ownership("44444444-4444-4444-8444-444444444444")
        )
        let volume = RuntimeInventoryVolume(
            runtimeID: "volume-a",
            name: "data",
            mountPoint: "/var/lib/data",
            capacityBytes: 8_192,
            usedBytes: 2_048,
            labels: [
                RuntimeInventoryLabel(
                    key: RuntimeManagedResourceIdentity.managedLabel,
                    value: "true"
                )
            ],
            ownership: ownership("55555555-5555-4555-8555-555555555555")
        )

        let first = try build(
            containers: [containerB, containerA],
            images: [image],
            networks: [network],
            volumes: [volume]
        )
        let second = try build(
            containers: [containerA, containerB],
            images: [image],
            networks: [network],
            volumes: [volume]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.containers.map(\.runtimeID), ["container-a", "container-b"])
        XCTAssertEqual(first.machine.services.map(\.identifier), ["api-server", "network-service"])
        XCTAssertEqual(first.containers[0].labels.map(\.key), [
            RuntimeManagedResourceIdentity.managedLabel,
            "org.example.role"
        ])
        XCTAssertEqual(first.containers[0].ports.map(\.containerPort), [80, 443])
        XCTAssertEqual(first.containers[0].mounts.map(\.target), ["/cache", "/data"])
        XCTAssertEqual(first.containers[0].networks.map(\.networkID), ["network-a", "network-z"])
        XCTAssertEqual(first.images[0].references, first.images[0].references.sorted())
        XCTAssertEqual(first.networks[0].addresses, first.networks[0].addresses.sorted())
        XCTAssertEqual(first.semanticSHA256.count, 64)
        XCTAssertNotNil(first.semanticSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression))

        let changed = try build(
            containers: [
                makeContainer(
                    runtimeID: "container-a",
                    name: "api",
                    resourceUUID: "33333333-3333-4333-8333-333333333333",
                    lifecycle: .failed
                ),
                containerB
            ],
            images: [image],
            networks: [network],
            volumes: [volume]
        )
        XCTAssertNotEqual(first.semanticSHA256, changed.semanticSHA256)
    }

    func testSemanticDigestExcludesVolatileUsageWhileRetainingSamples() throws {
        let first = try build(
            containers: [
                makeContainer(
                    runtimeID: "container-a",
                    name: "api",
                    cpuUsageMicroseconds: 100
                )
            ]
        )
        let second = try build(
            containers: [
                makeContainer(
                    runtimeID: "container-a",
                    name: "api",
                    cpuUsageMicroseconds: 101
                )
            ]
        )

        XCTAssertNotEqual(first.containers[0].usage, second.containers[0].usage)
        XCTAssertEqual(first.semanticSHA256, second.semanticSHA256)
    }

    func testMalformedHealthPortsAllocationsAndImagesFailClosed() {
        let container = makeContainer(
            runtimeID: "container",
            name: "api",
            health: RuntimeInventoryHealth(availability: .available)
        )
        assertInventoryError(.invalidHealth) {
            try self.build(containers: [container])
        }

        let invalidPort = makeContainer(
            runtimeID: "container",
            name: "api",
            ports: [RuntimeInventoryPort(hostPort: 70_000, containerPort: 80, protocolName: .tcp)]
        )
        assertInventoryError(.malformedRecord) {
            try self.build(containers: [invalidPort])
        }

        let invalidAllocation = makeContainer(
            runtimeID: "container",
            name: "api",
            allocation: RuntimeInventoryAllocation(cpuCount: 0)
        )
        assertInventoryError(.malformedRecord) {
            try self.build(containers: [invalidAllocation])
        }

        let invalidImage = RuntimeInventoryImage(
            runtimeID: "image",
            descriptorDigest: "sha256:invalid",
            references: ["example/image:latest"],
            variants: [],
            labels: []
        )
        assertInventoryError(.malformedRecord) {
            try self.build(images: [invalidImage])
        }
    }

    func testManagedLabelsNeverCreateOwnershipWithoutUUIDEvidence() {
        let labelOnly = makeContainer(
            runtimeID: "container-a",
            name: "api",
            labels: [
                RuntimeInventoryLabel(
                    key: RuntimeManagedResourceIdentity.managedLabel,
                    value: "true"
                )
            ]
        )
        assertInventoryError(.invalidOwnershipEvidence) {
            try self.build(containers: [labelOnly])
        }

        let ownershipOnly = makeContainer(
            runtimeID: "container-a",
            name: "api",
            labels: [],
            ownership: ownership("77777777-7777-4777-8777-777777777777")
        )
        assertInventoryError(.invalidOwnershipEvidence) {
            try self.build(containers: [ownershipOnly])
        }

        let invalidUUID = makeContainer(
            runtimeID: "container-a",
            name: "api",
            ownership: RuntimeInventoryOwnershipEvidence(
                resourceUUID: "container-a",
                projectUUID: projectUUID,
                resourceGeneration: 1,
                projectGeneration: 1,
                providerID: .appleContainerCLI,
                providerGeneration: 1,
                fencingToken: "33333333-3333-4333-8333-333333333333"
            )
        )
        assertInventoryError(.invalidOwnershipEvidence) {
            try self.build(containers: [invalidUUID])
        }

        let conflictingLabels = makeContainer(
            runtimeID: "container-a",
            name: "api",
            labels: [
                RuntimeInventoryLabel(key: "role", value: "api"),
                RuntimeInventoryLabel(key: "role", value: "worker")
            ]
        )
        assertInventoryError(.conflictingLabel) {
            try self.build(containers: [conflictingLabels])
        }

        let sharedUUID = "66666666-6666-4666-8666-666666666666"
        let first = makeContainer(
            runtimeID: "container-a",
            name: "api",
            ownership: ownership(sharedUUID)
        )
        let second = makeContainer(
            runtimeID: "container-b",
            name: "worker",
            ownership: ownership(sharedUUID)
        )
        assertInventoryError(.duplicateOwnershipUUID) {
            try self.build(containers: [first, second])
        }
    }

    func testRuntimeNamesMayCollideButRuntimeIDsMayNot() throws {
        let first = makeContainer(runtimeID: "container-a", name: "shared-name")
        let second = makeContainer(runtimeID: "container-b", name: "shared-name")
        let inventory = try build(containers: [second, first])

        XCTAssertEqual(inventory.containers.count, 2)
        XCTAssertEqual(inventory.containers.map(\.name), ["shared-name", "shared-name"])
        XCTAssertEqual(inventory.containers.map(\.runtimeID), ["container-a", "container-b"])

        assertInventoryError(.duplicateIdentity) {
            try self.build(containers: [first, first])
        }
    }

    func testLargeInventoryHonorsExactCollectionBoundary() throws {
        let maximum = (0..<RuntimeInventoryLimits.maximumContainers).map { index in
            makeContainer(runtimeID: String(format: "container-%04d", index), name: "service")
        }
        let inventory = try build(containers: maximum)
        XCTAssertEqual(inventory.containers.count, RuntimeInventoryLimits.maximumContainers)

        assertInventoryError(.limitExceeded) {
            try self.build(
                containers: maximum + [
                    self.makeContainer(runtimeID: "container-over-limit", name: "service")
                ]
            )
        }
    }

    func testInventoryRedactsLabelsInitConfigurationMountsAndReferences() throws {
        let secret = "synthetic-top-secret"
        let container = makeContainer(
            runtimeID: "container-a",
            name: "token=\(secret)",
            imageReference: "registry.example/api:latest?token=\(secret)",
            labels: [RuntimeInventoryLabel(key: "token=\(secret)", value: secret)],
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: "/bin/server",
                arguments: ["authorization=\(secret)"],
                environment: [RuntimeInventoryEnvironmentEntry(name: "PASSWORD", value: secret)]
            ),
            mounts: [
                RuntimeInventoryMount(
                    source: "keychain://service/account",
                    target: "/run/credential",
                    kind: .bind,
                    access: .readOnly
                )
            ]
        )
        let inventory = try build(containers: [container])
        let observed = try XCTUnwrap(inventory.containers.first)

        XCTAssertFalse(String(describing: inventory).contains(secret))
        XCTAssertFalse(String(describing: inventory).contains("keychain://service/account"))
        XCTAssertEqual(observed.labels[0].value, RuntimeRedactionPolicy.default.replacement)
        XCTAssertEqual(observed.initConfiguration.environment[0].value, RuntimeRedactionPolicy.default.replacement)
        XCTAssertTrue(observed.initConfiguration.arguments[0].contains(RuntimeRedactionPolicy.default.replacement))
        XCTAssertTrue(observed.mounts[0].source.contains(RuntimeRedactionPolicy.default.replacement))
        XCTAssertTrue(observed.imageReference.contains(RuntimeRedactionPolicy.default.replacement))
    }

    func testSemanticDigestIsIndependentOfDiagnosticRedactionPolicy() throws {
        let secret = "synthetic-top-secret"
        let container = makeContainer(
            runtimeID: "container-a",
            name: "token=\(secret)",
            imageReference: "registry.example/api:latest?token=\(secret)"
        )
        let firstPolicy = RuntimeRedactionPolicy(
            replacement: "[MASK-ONE]",
            sensitiveKeyFragments: RuntimeRedactionPolicy.default.sensitiveKeyFragments
        )
        let secondPolicy = RuntimeRedactionPolicy(
            replacement: "[MASK-TWO]",
            sensitiveKeyFragments: RuntimeRedactionPolicy.default.sensitiveKeyFragments
        )

        let first = try build(containers: [container], redactionPolicy: firstPolicy)
        let second = try build(containers: [container], redactionPolicy: secondPolicy)

        XCTAssertNotEqual(first.containers[0].name, second.containers[0].name)
        XCTAssertTrue(first.containers[0].name.contains(firstPolicy.replacement))
        XCTAssertTrue(second.containers[0].name.contains(secondPolicy.replacement))
        XCTAssertFalse(String(describing: first).contains(secret))
        XCTAssertFalse(String(describing: second).contains(secret))
        XCTAssertLessThanOrEqual(
            first.containers[0].name.utf8.count,
            RuntimeInventoryLimits.maximumStringBytes
        )
        XCTAssertLessThanOrEqual(
            second.containers[0].name.utf8.count,
            RuntimeInventoryLimits.maximumStringBytes
        )
        XCTAssertEqual(first.semanticSHA256, second.semanticSHA256)
    }

    func testInventoryBuildHonorsCancellationWithoutPartialResult() {
        XCTAssertThrowsError(
            try build(
                containers: [makeContainer(runtimeID: "container", name: "api")],
                cancellationCheck: { throw CancellationError() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRequiredMachineServiceLossMustBeReportedAsDegradedOrUnavailable() throws {
        let lostService = RuntimeInventoryService(
            identifier: "api-server",
            state: .unavailable,
            required: true
        )
        let degraded = RuntimeInventoryMachine(
            state: .degraded,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1.1.0",
            services: [lostService]
        )
        let inventory = try build(machine: degraded)
        XCTAssertEqual(inventory.machine.state, .degraded)
        XCTAssertEqual(inventory.machine.services[0].state, .unavailable)

        let falselyRunning = RuntimeInventoryMachine(
            state: .running,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1.1.0",
            services: [lostService]
        )
        assertInventoryError(.invalidMachineState) {
            try self.build(machine: falselyRunning)
        }
    }

    private let projectUUID = "11111111-1111-4111-8111-111111111111"

    private func build(
        machine: RuntimeInventoryMachine? = nil,
        containers: [RuntimeInventoryContainer] = [],
        images: [RuntimeInventoryImage] = [],
        networks: [RuntimeInventoryNetwork] = [],
        volumes: [RuntimeInventoryVolume] = [],
        redactionPolicy: RuntimeRedactionPolicy = .default,
        cancellationCheck: () throws -> Void = {}
    ) throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: machine ?? healthyMachine(),
            containers: containers,
            images: images,
            networks: networks,
            volumes: volumes,
            redactionPolicy: redactionPolicy,
            cancellationCheck: cancellationCheck
        )
    }

    private func healthyMachine() -> RuntimeInventoryMachine {
        RuntimeInventoryMachine(
            state: .running,
            operatingSystem: "macOS 26.0",
            architecture: "arm64",
            runtimeVersion: "1.1.0",
            services: [
                RuntimeInventoryService(identifier: "network-service", state: .running, required: true),
                RuntimeInventoryService(identifier: "api-server", state: .running, required: true)
            ]
        )
    }

    private func makeContainer(
        runtimeID: String,
        name: String,
        resourceUUID: String? = nil,
        imageReference: String = "registry.example/api:1.1.0",
        lifecycle: RuntimeInventoryLifecycleState = .running,
        health: RuntimeInventoryHealth = RuntimeInventoryHealth(
            availability: .available,
            state: .healthy
        ),
        labels: [RuntimeInventoryLabel]? = nil,
        ownership explicitOwnership: RuntimeInventoryOwnershipEvidence? = nil,
        initConfiguration: RuntimeInventoryInitConfiguration = RuntimeInventoryInitConfiguration(
            executable: "/bin/server",
            arguments: ["serve", "--port", "80"],
            environment: [
                RuntimeInventoryEnvironmentEntry(name: "LOG_LEVEL", value: "info"),
                RuntimeInventoryEnvironmentEntry(name: "MODE", value: "test")
            ],
            workingDirectory: "/app",
            user: "1000:1000"
        ),
        ports: [RuntimeInventoryPort] = [
            RuntimeInventoryPort(hostPort: 8443, containerPort: 443, protocolName: .tcp),
            RuntimeInventoryPort(hostPort: 8080, containerPort: 80, protocolName: .tcp)
        ],
        mounts: [RuntimeInventoryMount] = [
            RuntimeInventoryMount(source: "cache", target: "/cache", kind: .volume, access: .readWrite),
            RuntimeInventoryMount(source: "/tmp/data", target: "/data", kind: .bind, access: .readOnly)
        ],
        networks: [RuntimeInventoryNetworkAttachment] = [
            RuntimeInventoryNetworkAttachment(networkID: "network-z", addresses: ["fd00::2"]),
            RuntimeInventoryNetworkAttachment(networkID: "network-a", addresses: ["192.168.64.2"])
        ],
        allocation: RuntimeInventoryAllocation? = RuntimeInventoryAllocation(
            cpuCount: 2,
            memoryBytes: 1_048_576,
            storageBytes: 8_388_608
        ),
        cpuUsageMicroseconds: UInt64 = 100
    ) -> RuntimeInventoryContainer {
        let resolvedOwnership = explicitOwnership ?? resourceUUID.map(ownership)
        let resolvedLabels = labels ?? (resolvedOwnership == nil ? [] : [
            RuntimeInventoryLabel(key: "org.example.role", value: "api"),
            RuntimeInventoryLabel(key: RuntimeManagedResourceIdentity.managedLabel, value: "true")
        ])
        return RuntimeInventoryContainer(
            runtimeID: runtimeID,
            name: name,
            imageID: "image-a",
            imageReference: imageReference,
            lifecycle: lifecycle,
            health: health,
            labels: resolvedLabels,
            ownership: resolvedOwnership,
            initConfiguration: initConfiguration,
            ports: ports,
            mounts: mounts,
            networks: networks,
            allocation: allocation,
            usage: RuntimeInventoryUsage(
                cpuUsageMicroseconds: cpuUsageMicroseconds,
                memoryUsageBytes: 1_024,
                memoryLimitBytes: 1_048_576,
                networkReceiveBytes: 10,
                networkTransmitBytes: 20,
                blockReadBytes: 30,
                blockWriteBytes: 40,
                processCount: 3
            ),
            services: [
                RuntimeInventoryService(identifier: "worker", state: .running, required: false),
                RuntimeInventoryService(identifier: "init", state: .running, required: true)
            ]
        )
    }

    private func ownership(_ resourceUUID: String) -> RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID,
            projectUUID: projectUUID,
            resourceGeneration: 1,
            projectGeneration: 1,
            providerID: .appleContainerCLI,
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private func assertInventoryError<T>(
        _ expected: RuntimeInventoryError,
        operation: () throws -> T
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? RuntimeInventoryError, expected)
        }
    }
}
