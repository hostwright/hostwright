import Foundation
import XCTest
@testable import HostwrightRuntime

final class AppleContainerInventoryParserTests: XCTestCase {
    func testBuildsCompleteDeterministicVersionedInventoryAndRedactsSecrets() throws {
        for version in ["1.0.0", "1.1.0"] {
            let outputs = try outputs(version: version)
            let first = try AppleContainerInventoryParser.parse(outputs: outputs)
            let reordered = try AppleContainerInventoryParser.parse(
                outputs: try self.outputs(
                    version: version,
                    containers: reversedJSONArray(outputs.containers)
                )
            )

            XCTAssertEqual(first, reordered)
            XCTAssertEqual(first.semanticSHA256.count, 64)
            XCTAssertEqual(first.containers.count, 2)

            let managed = try XCTUnwrap(
                first.containers.first { $0.runtimeID == managedContainerID }
            )
            XCTAssertEqual(managed.lifecycle, .running)
            XCTAssertEqual(managed.health, RuntimeInventoryHealth(availability: .unsupported))
            XCTAssertEqual(managed.imageReference, "ghcr.io/example/api:\(version)")
            XCTAssertEqual(managed.initConfiguration.executable, "/usr/local/bin/api")
            XCTAssertEqual(managed.initConfiguration.arguments, ["serve", "--token=[REDACTED]"])
            XCTAssertEqual(managed.initConfiguration.user, "1000:1000")
            XCTAssertEqual(
                Dictionary(uniqueKeysWithValues: managed.initConfiguration.environment.map { ($0.name, $0.value) }),
                ["API_TOKEN": "[REDACTED]", "EMPTY": "", "PLAIN": "value"]
            )
            XCTAssertEqual(managed.ports.map(\.hostPort), [8080, 8081])
            XCTAssertEqual(managed.ports.map(\.containerPort), [80, 81])
            XCTAssertEqual(managed.mounts.map(\.target), ["/cache", "/srv/data"])
            XCTAssertEqual(managed.mounts.map(\.kind), [.volume, .bind])
            XCTAssertEqual(managed.mounts.map(\.access), [.readWrite, .readOnly])
            XCTAssertEqual(managed.allocation?.cpuCount, 4)
            XCTAssertEqual(managed.allocation?.memoryBytes, 8_589_934_592)
            XCTAssertEqual(managed.allocation?.storageBytes, 68_719_476_736)
            XCTAssertEqual(managed.usage?.processCount, version == "1.0.0" ? 2 : 3)
            XCTAssertEqual(managed.networks.map(\.networkID), ["default"])
            XCTAssertEqual(
                managed.networks[0].addresses,
                version == "1.0.0"
                    ? ["192.168.64.2/24", "fdae:498:8db7:d30c::2/64"]
                    : ["192.168.64.3/24", "fdae:498:8db7:d30c::3/64"]
            )
            XCTAssertEqual(managed.services, [
                RuntimeInventoryService(identifier: "init", state: .running, required: true)
            ])

            let ownership = try XCTUnwrap(managed.ownership)
            XCTAssertEqual(ownership.resourceUUID, "22222222-2222-4222-8222-222222222222")
            XCTAssertEqual(ownership.projectUUID, "11111111-1111-4111-8111-111111111111")
            XCTAssertEqual(ownership.resourceGeneration, 2)
            XCTAssertEqual(ownership.projectGeneration, 3)
            XCTAssertEqual(ownership.providerID, .appleContainerCLI)
            XCTAssertEqual(ownership.providerGeneration, 4)
            XCTAssertEqual(ownership.fencingToken, "33333333-3333-4333-8333-333333333333")
            XCTAssertEqual(
                managed.labels.first { $0.key == RuntimeManagedResourceIdentity.fencingTokenLabel }?.value,
                "[REDACTED]"
            )

            let nameOnly = try XCTUnwrap(
                first.containers.first { $0.runtimeID == managedLookingUnownedContainerID }
            )
            XCTAssertNil(nameOnly.ownership)
            XCTAssertNil(nameOnly.usage)
            XCTAssertEqual(nameOnly.lifecycle, .stopped)
            XCTAssertEqual(nameOnly.initConfiguration.user, "nobody")

            XCTAssertEqual(first.images.count, 1)
            XCTAssertEqual(first.images[0].references, ["ghcr.io/example/api:\(version)"])
            XCTAssertEqual(first.images[0].variants[0].architecture, "arm64")
            XCTAssertEqual(first.networks.count, 1)
            XCTAssertEqual(first.networks[0].kind, "container-network-vmnet:nat")
            XCTAssertEqual(first.volumes.count, 1)
            XCTAssertEqual(
                first.volumes[0].mountPoint,
                "/var/lib/container/volumes/hostwright-cache"
            )
            XCTAssertEqual(first.machine.state, .running)
            XCTAssertEqual(first.machine.runtimeVersion, version)
            XCTAssertEqual(first.machine.operatingSystem, "linux")
            XCTAssertEqual(first.machine.architecture, "arm64")
            XCTAssertEqual(
                first.machine.services.map(\.identifier),
                ["container-apiserver", "machine:hostwright-machine"]
            )
        }

        XCTAssertEqual(AppleContainerInventoryParser.healthDetailsAvailability, .unsupported)
        XCTAssertEqual(AppleContainerInventoryParser.processDetailsAvailability, .unsupported)
    }

    func testRejectsPartialOrConflictingOwnershipWithoutNameFallback() throws {
        let valid = try fixture("apple-container-1.1.0-inventory-containers.json")
        let mutations = [
            valid.replacingOccurrences(
                of: "\"dev.hostwright.provider-id\": \"apple-container-cli\"",
                with: "\"dev.hostwright.provider-id\": \"apple-containerization\""
            ),
            valid.replacingOccurrences(
                of: "        \"dev.hostwright.fencing-token\": \"33333333-3333-4333-8333-333333333333\",\n",
                with: ""
            ),
            valid.replacingOccurrences(
                of: "\"dev.hostwright.resource-id\": \"\(managedContainerID)\"",
                with: "\"dev.hostwright.resource-id\": \"forged-resource\""
            ),
            valid.replacingOccurrences(
                of: "\"dev.hostwright.resource-uuid\": \"22222222-2222-4222-8222-222222222222\"",
                with: "\"dev.hostwright.resource-uuid\": \"22222222-2222-4222-8222-22222222222A\""
            ),
            valid.replacingOccurrences(
                of: "\"dev.hostwright.provider-generation\": \"4\"",
                with: "\"dev.hostwright.provider-generation\": \"04\""
            )
        ]

        for containers in mutations {
            XCTAssertThrowsError(
                try AppleContainerInventoryParser.parse(
                    outputs: try outputs(version: "1.1.0", containers: containers)
                )
            )
        }
    }

    func testRejectsPartialConflictingNestedAndUnsupportedContainerDetails() throws {
        let valid = try fixture("apple-container-1.1.0-inventory-containers.json")
        let malformed = [
            valid.replacingOccurrences(of: "\"initProcess\":", with: "\"missingInitProcess\":"),
            valid.replacingOccurrences(
                of: "      \"terminal\": false,",
                with: "      \"terminal\": false,\n      \"terminal\": true,"
            ),
            valid.replacingOccurrences(
                of: "\"PLAIN=value\", \"API_TOKEN=fixture-secret\"",
                with: "\"PLAIN=value\", \"PLAIN=conflict\", \"API_TOKEN=fixture-secret\""
            ),
            valid.replacingOccurrences(
                of: "\"rlimits\": []",
                with: "\"rlimits\": [{\"limit\":\"RLIMIT_NOFILE\",\"soft\":1024,\"hard\":2048}]"
            ),
            valid.replacingOccurrences(
                of: "\"options\": [\"ro\"]",
                with: "\"options\": [\"ro\",\"rw\"]"
            ),
            valid.replacingOccurrences(
                of: "\"hostname\": \"api\",\n          \"ipv4Address\"",
                with: "\"hostname\": \"conflict\",\n          \"ipv4Address\""
            ),
            valid.replacingOccurrences(
                of: "\"digest\": \"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"",
                with: "\"digest\": \"sha256:not-a-digest\""
            ),
            valid.replacingOccurrences(
                of: "\"architecture\": \"arm64\"",
                with: "\"architecture\": \"\""
            ),
            valid.replacingOccurrences(
                of: "\"cpuOverhead\": 1",
                with: "\"cpuOverhead\": -1"
            ),
            valid.replacingOccurrences(
                of: "\"cache\": \"on\"",
                with: "\"cache\": \"\""
            )
        ]

        for containers in malformed {
            XCTAssertThrowsError(
                try AppleContainerInventoryParser.parse(
                    outputs: try outputs(version: "1.1.0", containers: containers)
                )
            )
        }

        let conflictingTopLevelID = valid.replacingOccurrences(
            of: "    \"id\": \"\(managedContainerID)\",\n    \"status\":",
            with: "    \"id\": \"conflicting-id\",\n    \"status\":"
        )
        XCTAssertThrowsError(
            try AppleContainerInventoryParser.parse(
                outputs: try outputs(version: "1.1.0", containers: conflictingTopLevelID)
            )
        )
    }

    func testRejectsUnknownOrConflictingStatsAndOversizedFeeds() throws {
        let validOutputs = try outputs(version: "1.1.0")
        let stats = try fixture("apple-container-1.1.0-stats.json")

        XCTAssertThrowsError(
            try AppleContainerInventoryParser.parse(
                outputs: AppleContainerInventoryOutputs(
                    version: validOutputs.version,
                    systemStatus: validOutputs.systemStatus,
                    containers: validOutputs.containers,
                    images: validOutputs.images,
                    networks: validOutputs.networks,
                    volumes: validOutputs.volumes,
                    machines: validOutputs.machines,
                    statsByContainerID: ["unknown-container": stats]
                )
            )
        )
        XCTAssertThrowsError(
            try AppleContainerInventoryParser.parse(
                outputs: AppleContainerInventoryOutputs(
                    version: validOutputs.version,
                    systemStatus: validOutputs.systemStatus,
                    containers: validOutputs.containers,
                    images: validOutputs.images,
                    networks: validOutputs.networks,
                    volumes: validOutputs.volumes,
                    machines: validOutputs.machines,
                    statsByContainerID: [managedLookingUnownedContainerID: stats]
                )
            )
        )
        XCTAssertThrowsError(
            try AppleContainerInventoryParser.parse(
                outputs: AppleContainerInventoryOutputs(
                    version: validOutputs.version,
                    systemStatus: validOutputs.systemStatus,
                    containers: String(
                        repeating: " ",
                        count: AppleContainerInventoryParser.maximumContainerBytes + 1
                    ),
                    images: validOutputs.images,
                    networks: validOutputs.networks,
                    volumes: validOutputs.volumes,
                    machines: validOutputs.machines
                )
            )
        )
        XCTAssertThrowsError(
            try AppleContainerInventoryParser.parse(
                outputs: AppleContainerInventoryOutputs(
                    version: validOutputs.version,
                    systemStatus: validOutputs.systemStatus,
                    containers: validOutputs.containers,
                    images: String(
                        repeating: " ",
                        count: AppleContainerInventoryParser.maximumImageBytes + 1
                    ),
                    networks: validOutputs.networks,
                    volumes: validOutputs.volumes,
                    machines: validOutputs.machines
                )
            )
        )
    }

    func testDerivesStoppedUnavailableAndDegradedMachineStates() throws {
        let stopped = try AppleContainerInventoryParser.parse(
            outputs: try outputs(
                version: "1.1.0",
                status: """
                {"status":"not running","apiServerVersion":"","apiServerBuild":""}
                """,
                machines: "[]"
            )
        )
        XCTAssertEqual(stopped.machine.state, .stopped)

        let unavailable = try AppleContainerInventoryParser.parse(
            outputs: try outputs(
                version: "1.1.0",
                status: """
                {"status":"unregistered","apiServerVersion":"","apiServerBuild":""}
                """,
                machines: "[]"
            )
        )
        XCTAssertEqual(unavailable.machine.state, .unavailable)

        let degradedMachines = try fixture("apple-container-1.1.0-machine-list.json")
            .replacingOccurrences(of: "\"status\": \"running\"", with: "\"status\": \"stopped\"")
        let degraded = try AppleContainerInventoryParser.parse(
            outputs: try outputs(version: "1.1.0", machines: degradedMachines)
        )
        XCTAssertEqual(degraded.machine.state, .degraded)
    }

    private let managedContainerID = "hostwright-v2-demo-api-8022a4342ff931db15cdc03b748de2b6"
    private let managedLookingUnownedContainerID =
        "hostwright-v2-demo-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    private func outputs(
        version: String,
        containers: String? = nil,
        status: String? = nil,
        machines: String? = nil
    ) throws -> AppleContainerInventoryOutputs {
        AppleContainerInventoryOutputs(
            version: try fixture("apple-container-\(version)-version.txt"),
            systemStatus: try status ?? fixture("apple-container-\(version)-system-status.json"),
            containers: try containers ?? fixture("apple-container-\(version)-inventory-containers.json"),
            images: try fixture("apple-container-\(version)-image-list.json"),
            networks: try fixture("apple-container-\(version)-network-list.json"),
            volumes: try fixture("apple-container-\(version)-volume-list.json"),
            machines: try machines ?? fixture("apple-container-\(version)-machine-list.json"),
            statsByContainerID: [
                managedContainerID: try fixture("apple-container-\(version)-stats.json")
            ]
        )
    }

    private func reversedJSONArray(_ text: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let array = try XCTUnwrap(object as? [Any])
        let data = try JSONSerialization.data(withJSONObject: Array(array.reversed()))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }
}
