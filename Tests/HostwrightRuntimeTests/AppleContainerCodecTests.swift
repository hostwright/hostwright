import Foundation
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class AppleContainerCodecTests: XCTestCase {
    func testSelectsOnlyExactOnePointZeroAndOnePointOneVersionOutputs() throws {
        let onePointZero = try fixture("apple-container-1.0.0-version.txt")
        let onePointOne = try fixture("apple-container-1.1.0-version.txt")

        XCTAssertEqual(
            try AppleContainerCLICodec.select(fromVersionOutput: onePointZero),
            .v1_0_0
        )
        XCTAssertEqual(
            try AppleContainerCLICodec.select(fromVersionOutput: onePointOne),
            .v1_1_0
        )
        XCTAssertEqual(
            AppleContainerVersionParser.parseCLIIdentity(onePointOne),
            AppleContainerCLIIdentity(version: "1.1.0", build: "release", commit: "5973b9c")
        )

        let malformed = [
            "container CLI version 1.1.0",
            "container CLI version 01.1.0 (build: release, commit: 5973b9c)",
            "container CLI version 1.1.0-beta.1 (build: release, commit: 5973b9c)",
            "container CLI version 1.1.0 (commit: 5973b9c, build: release)",
            "container CLI version 1.1.0 (build: release, commit: 5973b9c) trailing"
        ]
        for output in malformed {
            XCTAssertThrowsError(try AppleContainerCLICodec.select(fromVersionOutput: output), output)
        }
        XCTAssertThrowsError(
            try AppleContainerCLICodec.select(
                fromVersionOutput: String(repeating: "x", count: AppleContainerVersionParser.maximumBytes + 1)
            )
        )
    }

    func testUnsupportedVersionFailsMutationPreflightBeforeCommandConstruction() {
        var constructedMutation = false

        XCTAssertThrowsError(
            try {
                _ = try AppleContainerCLICodec.selectForMutation(
                    fromVersionOutput: "container CLI version 1.2.0 (build: release, commit: abcdef0)\n"
                )
                constructedMutation = true
            }()
        ) { error in
            guard case RuntimeAdapterError.unsupportedRuntime = error else {
                return XCTFail("Expected unsupportedRuntime, got \(error).")
            }
        }
        XCTAssertFalse(constructedMutation)
    }

    func testVersionBoundCommandMatrixUsesJSONOnlyForSemanticReads() {
        let executable = ResolvedRuntimeExecutable(name: "container", path: "/usr/bin/container")

        for codec in AppleContainerCLICodec.allCases {
            XCTAssertEqual(
                AppleContainerCommand.spec(kind: .systemStatus, codec: codec, executable: executable).arguments,
                ["system", "status", "--format", "json"]
            )
            XCTAssertEqual(
                AppleContainerCommand.spec(kind: .listContainers, codec: codec, executable: executable).arguments,
                ["list", "--all", "--format", "json"]
            )
            XCTAssertEqual(
                AppleContainerCommand.spec(kind: .listImages, codec: codec, executable: executable).arguments,
                ["image", "list", "--format", "json"]
            )
            let networkSpec = AppleContainerCommand.spec(
                kind: .listNetworks,
                codec: codec,
                executable: executable
            )
            XCTAssertEqual(networkSpec.arguments, ["network", "list", "--format", "json"])
            XCTAssertEqual(networkSpec.classification, .readOnly)
            XCTAssertEqual(networkSpec.exitStatusPolicy, .zeroOnly)
            XCTAssertEqual(networkSpec.purpose, "Read Apple container network list as JSON.")

            let volumeSpec = AppleContainerCommand.spec(
                kind: .listVolumes,
                codec: codec,
                executable: executable
            )
            XCTAssertEqual(volumeSpec.arguments, ["volume", "list", "--format", "json"])
            XCTAssertEqual(volumeSpec.classification, .readOnly)
            XCTAssertEqual(volumeSpec.exitStatusPolicy, .zeroOnly)
            XCTAssertEqual(volumeSpec.purpose, "Read Apple container volume list as JSON.")

            let machineSpec = AppleContainerCommand.spec(
                kind: .listMachines,
                codec: codec,
                executable: executable
            )
            XCTAssertEqual(machineSpec.arguments, ["machine", "list", "--format", "json"])
            XCTAssertEqual(machineSpec.classification, .readOnly)
            XCTAssertEqual(machineSpec.exitStatusPolicy, .zeroOnly)
            XCTAssertEqual(machineSpec.purpose, "Read Apple container machine list as JSON.")
            XCTAssertEqual(
                AppleContainerCommand.spec(
                    kind: .stats(containerID: resourceIdentifier),
                    codec: codec,
                    executable: executable
                ).arguments,
                ["stats", resourceIdentifier, "--no-stream", "--format", "json"]
            )
            XCTAssertEqual(
                AppleContainerCommand.spec(
                    kind: .logs(containerID: resourceIdentifier, tail: 25),
                    codec: codec,
                    executable: executable
                ).arguments,
                ["logs", "-n", "25", resourceIdentifier]
            )

            let mutation = AppleContainerCommand.spec(
                kind: .startContainer(containerID: resourceIdentifier),
                codec: codec,
                executable: executable
            )
            XCTAssertEqual(mutation.arguments, ["start", resourceIdentifier])
            XCTAssertFalse(mutation.arguments.contains("--format"))
        }
    }

    func testBothVersionCodecsDecodeSemanticFixtureMatrix() throws {
        for codec in AppleContainerCLICodec.allCases {
            let version = codec.rawValue
            let versionOutput = try fixture("apple-container-\(version)-version.txt")
            let status = try codec.decodeSystemStatus(
                try fixture("apple-container-\(version)-system-status.json"),
                versionOutput: versionOutput
            )
            XCTAssertEqual(status.cliVersion, version)
            XCTAssertEqual(status.serviceVersion, version)
            XCTAssertEqual(status.serviceState, .running)

            let observation = try codec.decodeObservation(
                try fixture("apple-container-\(version)-list.json"),
                desiredState: desiredState,
                metadata: metadata
            )
            XCTAssertEqual(observation.services.count, 1)
            XCTAssertEqual(observation.services[0].resourceIdentifier, resourceIdentifier)
            XCTAssertEqual(observation.services[0].lifecycleState, .running)
            XCTAssertEqual(observation.services[0].ports.first?.hostPort, 8080)
            XCTAssertEqual(observation.services[0].networks.first?.name, "default")

            let image = "ghcr.io/example/api:\(version)"
            let imageOutput = try fixture("apple-container-\(version)-image-list.json")
            XCTAssertTrue(try codec.containsLocalImage(image, in: imageOutput))
            let evidence = try codec.decodeLocalImageEvidence(
                imageOutput,
                expectedReference: image,
                preferredArchitecture: "arm64"
            )
            XCTAssertEqual(evidence.reference, image)
            XCTAssertEqual(evidence.architecture, "arm64")

            let usage = try codec.decodeResourceUsage(
                try fixture("apple-container-\(version)-stats.json"),
                expectedResourceIdentifier: resourceIdentifier
            )
            XCTAssertEqual(usage.resourceIdentifier, resourceIdentifier)
            XCTAssertGreaterThan(usage.processCount, 0)

            let networks = try codec.decodeNetworks(
                try fixture("apple-container-\(version)-network-list.json")
            )
            XCTAssertEqual(networks.count, 1)
            XCTAssertEqual(networks[0].id, "default")
            XCTAssertEqual(networks[0].name, "default")
            XCTAssertEqual(networks[0].mode, .nat)
            XCTAssertEqual(networks[0].plugin, "container-network-vmnet")
            XCTAssertEqual(networks[0].ipv4Subnet, "192.168.64.0/24")
            XCTAssertEqual(networks[0].ipv4Gateway, "192.168.64.1")
            XCTAssertEqual(networks[0].ipv6Subnet, "fdae:498:8db7:d30c::/64")

            let volumes = try codec.decodeVolumes(
                try fixture("apple-container-\(version)-volume-list.json")
            )
            XCTAssertEqual(volumes.count, 1)
            XCTAssertEqual(volumes[0].id, "hostwright-cache")
            XCTAssertEqual(volumes[0].name, "hostwright-cache")
            XCTAssertEqual(volumes[0].driver, "local")
            XCTAssertEqual(volumes[0].format, "ext4")
            XCTAssertEqual(volumes[0].sizeInBytes, 536_870_912)

            let machines = try codec.decodeMachines(
                try fixture("apple-container-\(version)-machine-list.json")
            )
            XCTAssertEqual(machines.count, 1)
            XCTAssertEqual(machines[0].id, "hostwright-machine")
            XCTAssertEqual(machines[0].status, .running)
            XCTAssertTrue(machines[0].isDefault)
            XCTAssertEqual(machines[0].ipAddress, "192.168.64.2")
            XCTAssertEqual(machines[0].cpuCount, 4)
            XCTAssertEqual(machines[0].memoryBytes, 8_589_934_592)
            XCTAssertEqual(machines[0].diskSizeBytes, 68_719_476_736)
        }
    }

    func testInfrastructureCodecsAcceptEmptyListsAndRejectAmbiguousOrPartialEvidence() throws {
        let codec = AppleContainerCLICodec.v1_1_0

        XCTAssertEqual(try codec.decodeNetworks("[]"), [])
        XCTAssertEqual(try codec.decodeVolumes("[]"), [])
        XCTAssertEqual(try codec.decodeMachines("[]"), [])

        XCTAssertThrowsError(
            try codec.decodeNetworks(
                "[\(networkEntry(id: "default", name: "conflicting"))]"
            )
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                "[\(volumeEntry(id: "cache", name: "conflicting"))]"
            )
        )
        XCTAssertThrowsError(
            try codec.decodeNetworks(
                "[\(networkEntry(id: "default", name: "default", configurationID: "forged"))]"
            )
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                "[\(volumeEntry(id: "cache", name: "cache", configurationID: "forged"))]"
            )
        )
        XCTAssertThrowsError(
            try codec.decodeMachines(
                "[\(machineEntry(id: "first", isDefault: true)),\(machineEntry(id: "second", isDefault: true))]"
            )
        )

        XCTAssertThrowsError(
            try codec.decodeMachines(
                "[\(machineEntry(id: "duplicate", isDefault: false)),\(machineEntry(id: "duplicate", isDefault: false))]"
            )
        )
        XCTAssertThrowsError(
            try codec.decodeNetworks(
                """
                [{
                  "id":"default",
                  "id":"forged",
                  "configuration":{
                    "name":"default",
                    "mode":"nat",
                    "creationDate":"2026-07-18T23:49:12Z",
                    "labels":{},
                    "plugin":"container-network-vmnet",
                    "options":{}
                  },
                  "status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}
                }]
                """
            )
        )

        XCTAssertThrowsError(
            try codec.decodeNetworks(
                """
                [{
                  "id":"default",
                  "configuration":{
                    "name":"default",
                    "mode":"nat",
                    "creationDate":"2026-07-18T23:49:12Z",
                    "labels":{},
                    "options":{}
                  },
                  "status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}
                }]
                """
            )
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                """
                [{
                  "id":"cache",
                  "configuration":{
                    "name":"cache",
                    "driver":"local",
                    "format":"ext4",
                    "creationDate":"2026-07-18T23:50:00Z",
                    "labels":{},
                    "options":{}
                  }
                }]
                """
            )
        )
        XCTAssertThrowsError(
            try codec.decodeMachines(
                """
                [{"id":"machine","status":"running","default":true,"cpus":4}]
                """
            )
        )
    }

    func testInfrastructureCodecsEnforceListStringMetadataAndByteBounds() {
        let codec = AppleContainerCLICodec.v1_1_0

        XCTAssertThrowsError(
            try codec.decodeNetworks(
                jsonArray(
                    repeating: networkEntry(id: "default", name: "default"),
                    count: AppleContainerNetworkListParser.maximumEntries + 1
                )
            )
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                jsonArray(
                    repeating: volumeEntry(id: "cache", name: "cache"),
                    count: AppleContainerVolumeListParser.maximumEntries + 1
                )
            )
        )
        XCTAssertThrowsError(
            try codec.decodeMachines(
                jsonArray(
                    repeating: machineEntry(id: "machine", isDefault: false),
                    count: AppleContainerMachineListParser.maximumEntries + 1
                )
            )
        )

        let oversizedNetworkID = String(
            repeating: "n",
            count: AppleContainerNetworkListParser.maximumStringBytes + 1
        )
        XCTAssertThrowsError(
            try codec.decodeNetworks(
                "[\(networkEntry(id: oversizedNetworkID, name: oversizedNetworkID))]"
            )
        )
        let oversizedVolumeID = String(
            repeating: "v",
            count: AppleContainerVolumeListParser.maximumStringBytes + 1
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                "[\(volumeEntry(id: oversizedVolumeID, name: oversizedVolumeID))]"
            )
        )
        let oversizedMachineID = String(
            repeating: "m",
            count: AppleContainerMachineListParser.maximumStringBytes + 1
        )
        XCTAssertThrowsError(
            try codec.decodeMachines(
                "[\(machineEntry(id: oversizedMachineID, isDefault: false))]"
            )
        )

        let excessiveLabels = (0...AppleContainerNetworkListParser.maximumMetadataEntries)
            .map { "\"key-\($0)\":\"value\"" }
            .joined(separator: ",")
        XCTAssertThrowsError(
            try codec.decodeNetworks(
                """
                [{
                  "id":"default",
                  "configuration":{
                    "name":"default",
                    "mode":"nat",
                    "creationDate":"2026-07-18T23:49:12Z",
                    "labels":{\(excessiveLabels)},
                    "plugin":"container-network-vmnet",
                    "options":{}
                  },
                  "status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}
                }]
                """
            )
        )

        XCTAssertThrowsError(
            try codec.decodeNetworks(
                String(repeating: " ", count: AppleContainerNetworkListParser.maximumBytes + 1)
            )
        )
        XCTAssertThrowsError(
            try codec.decodeVolumes(
                String(repeating: " ", count: AppleContainerVolumeListParser.maximumBytes + 1)
            )
        )
        XCTAssertThrowsError(
            try codec.decodeMachines(
                String(repeating: " ", count: AppleContainerMachineListParser.maximumBytes + 1)
            )
        )
    }

    func testSemanticDecodersRejectDuplicatePartialMalformedAndOversizedOutput() throws {
        let codec = AppleContainerCLICodec.v1_1_0
        let duplicateCriticalField = """
        [{
          "id":"\(resourceIdentifier)",
          "configuration":{
            "id":"\(resourceIdentifier)",
            "image":{"reference":"ghcr.io/example/api:1.1.0"},
            "labels":{},
            "publishedPorts":[]
          },
          "status":{"state":"running","state":"stopped","networks":[]}
        }]
        """
        XCTAssertThrowsError(
            try codec.decodeObservation(
                duplicateCriticalField,
                desiredState: desiredState,
                metadata: metadata
            )
        )

        let ambiguousIdentifiers = """
        [{
          "id":"\(resourceIdentifier)",
          "configuration":{
            "id":"hostwright-v2-demo-api-ffffffffffffffffffffffffffffffff",
            "image":{"reference":"ghcr.io/example/api:1.1.0"},
            "labels":{},
            "publishedPorts":[]
          },
          "status":{"state":"running","networks":[]}
        }]
        """
        XCTAssertThrowsError(
            try codec.decodeObservation(
                ambiguousIdentifiers,
                desiredState: desiredState,
                metadata: metadata
            )
        )

        let partialStats = """
        [{
          "id":"\(resourceIdentifier)",
          "cpuUsageUsec":1,
          "memoryUsageBytes":2,
          "memoryLimitBytes":3,
          "networkRxBytes":4,
          "networkTxBytes":5,
          "blockReadBytes":6,
          "blockWriteBytes":7
        }]
        """
        XCTAssertThrowsError(
            try codec.decodeResourceUsage(
                partialStats,
                expectedResourceIdentifier: resourceIdentifier
            )
        )
        XCTAssertThrowsError(
            try codec.containsLocalImage("ghcr.io/example/api:1.1.0", in: "[{\"configuration\":")
        )
        XCTAssertThrowsError(
            try codec.decodeSystemStatus(
                """
                {
                  "status":"running",
                  "apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)",
                  "apiServerBuild":"debug",
                  "apiServerCommit":"5973b9c",
                  "apiServerAppName":"container-apiserver"
                }
                """,
                versionOutput: try fixture("apple-container-1.1.0-version.txt")
            )
        )
        XCTAssertThrowsError(
            try codec.decodeObservation(
                String(repeating: " ", count: AppleContainerObservationParser.maximumBytes + 1),
                desiredState: desiredState,
                metadata: metadata
            )
        )
        XCTAssertThrowsError(
            try codec.decodeResourceUsage(
                String(repeating: " ", count: AppleContainerStatsParser.maximumBytes + 1),
                expectedResourceIdentifier: resourceIdentifier
            )
        )
        XCTAssertThrowsError(
            try codec.containsLocalImage(
                "ghcr.io/example/api:1.1.0",
                in: String(
                    repeating: " ",
                    count: AppleContainerImageListOutputParser.maximumBytes + 1
                )
            )
        )
        XCTAssertThrowsError(
            try codec.decodeSystemStatus(
                String(
                    repeating: " ",
                    count: AppleContainerSystemStatusParser.maximumBytes + 1
                ),
                versionOutput: try fixture("apple-container-1.1.0-version.txt")
            )
        )
    }

    func testLogsAreOpaqueAndBoundedAndMutationStdoutHasNoSemantics() throws {
        let codec = AppleContainerCLICodec.v1_1_0
        let opaque = "{not-json}\nplain text\n"
        XCTAssertEqual(try codec.decodeOpaqueLogs(opaque), opaque)
        XCTAssertThrowsError(
            try codec.decodeOpaqueLogs(
                String(repeating: "x", count: AppleContainerCLICodec.maximumLogBytes + 1)
            )
        )

        XCTAssertNoThrow(
            try codec.discardMutationOutput(
                "{\"id\":\"forged-resource\",\"status\":\"failed\"}"
            )
        )
        XCTAssertThrowsError(
            try codec.discardMutationOutput(
                String(repeating: "x", count: AppleContainerCLICodec.maximumMutationOutputBytes + 1)
            )
        )
    }

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    }

    private var resourceIdentifier: String {
        identity.managedResourceIdentifier
    }

    private var desiredState: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [
                DesiredRuntimeService(
                    identity: identity,
                    image: "ghcr.io/example/api:1.1.0",
                    ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
                )
            ]
        )
    }

    private var metadata: RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "AppleContainerCodecTests",
            adapterVersion: "test",
            runtimeName: "Apple container CLI",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func networkEntry(
        id: String,
        name: String,
        configurationID: String? = nil
    ) -> String {
        let encodedConfigurationID = configurationID.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {
          "id":"\(id)",
          "configuration":{
            \(encodedConfigurationID)
            "name":"\(name)",
            "mode":"nat",
            "creationDate":"2026-07-18T23:49:12Z",
            "labels":{},
            "plugin":"container-network-vmnet",
            "options":{}
          },
          "status":{"ipv4Subnet":"192.168.64.0/24","ipv4Gateway":"192.168.64.1"}
        }
        """
    }

    private func volumeEntry(
        id: String,
        name: String,
        configurationID: String? = nil
    ) -> String {
        let encodedConfigurationID = configurationID.map { "\"id\":\"\($0)\"," } ?? ""
        return """
        {
          "id":"\(id)",
          "configuration":{
            \(encodedConfigurationID)
            "name":"\(name)",
            "driver":"local",
            "format":"ext4",
            "source":"/var/lib/container/volumes/\(name)",
            "creationDate":"2026-07-18T23:50:00Z",
            "labels":{},
            "options":{}
          }
        }
        """
    }

    private func machineEntry(id: String, isDefault: Bool) -> String {
        """
        {
          "id":"\(id)",
          "status":"running",
          "default":\(isDefault),
          "cpus":4,
          "memory":8589934592
        }
        """
    }

    private func jsonArray(repeating entry: String, count: Int) -> String {
        "[\(Array(repeating: entry, count: count).joined(separator: ","))]"
    }
}
