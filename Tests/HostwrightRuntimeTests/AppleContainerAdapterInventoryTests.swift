import Foundation
import HostwrightTestSupport
import HostwrightCore
import HostwrightNetworking
import XCTest
@testable import HostwrightRuntime

final class AppleContainerAdapterInventoryTests: XCTestCase {
    func testProductionObservationUsesCompleteInventoryAndExactUUIDStateOwnership() async throws {
        let runner = try InventoryRuntimeProcessRunner(version: "1.1.0")
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [
                    AppleContainerCommand.executableName: "/usr/local/bin/container",
                    "sw_vers": "/usr/bin/sw_vers",
                    "uname": "/usr/bin/uname"
                ]
            ),
            processRunner: runner
        )
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
        let ownership = RuntimeInventoryOwnershipEvidence(
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            projectUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 2,
            projectGeneration: 3,
            providerID: .appleContainerCLI,
            providerGeneration: 4,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
        let state = DesiredRuntimeState(
            projectName: "demo",
            services: [DesiredRuntimeService(identity: identity, image: "ghcr.io/example/api:1.1.0")],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: identity.managedResourceIdentifier,
                    identity: identity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownership
                )
            ]
        )

        let observed = try await adapter.observe(desiredState: state)

        XCTAssertEqual(observed.capabilitySHA256?.count, 64)
        XCTAssertEqual(observed.services.count, 1)
        let service = try XCTUnwrap(observed.services.first)
        XCTAssertEqual(service.identity, identity)
        XCTAssertEqual(service.resourceIdentifier, identity.managedResourceIdentifier)
        XCTAssertEqual(service.lifecycleState, .running)
        XCTAssertEqual(service.healthState, .unknown)
        XCTAssertEqual(service.ports.map(\.hostPort), [8080, 8081])
        XCTAssertEqual(service.mounts.map(\.target), ["/cache", "/srv/data"])
        XCTAssertEqual(service.networks.map(\.name), ["default"])

        let calls = await runner.recordedSpecs()
        XCTAssertTrue(calls.allSatisfy { $0.classification == .readOnly })
        XCTAssertTrue(calls.contains { $0.arguments == ["network", "list", "--format", "json"] })
        XCTAssertTrue(calls.contains { $0.arguments == ["volume", "list", "--format", "json"] })
        XCTAssertTrue(calls.contains { $0.arguments == ["machine", "list", "--format", "json"] })
        XCTAssertTrue(calls.contains {
            $0.arguments == ["stats", identity.managedResourceIdentifier, "--no-stream", "--format", "json"]
        })
    }

    func testProductionObservationRejectsManagedLookingNameWithoutMatchingUUIDOwnership() async throws {
        let runner = try InventoryRuntimeProcessRunner(version: "1.1.0")
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [
                    AppleContainerCommand.executableName: "/usr/local/bin/container",
                    "sw_vers": "/usr/bin/sw_vers",
                    "uname": "/usr/bin/uname"
                ]
            ),
            processRunner: runner
        )
        let identity = RuntimeServiceIdentity(projectName: "demo", serviceName: "web")
        let nameCollision = "hostwright-v2-demo-web-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let state = DesiredRuntimeState(
            projectName: "demo",
            services: [DesiredRuntimeService(identity: identity, image: "busybox:latest")],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: nameCollision,
                    identity: identity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: RuntimeInventoryOwnershipEvidence(
                        resourceUUID: "44444444-4444-4444-8444-444444444444",
                        projectUUID: "11111111-1111-4111-8111-111111111111",
                        resourceGeneration: 1,
                        projectGeneration: 3,
                        providerID: .appleContainerCLI,
                        providerGeneration: 4,
                        fencingToken: "33333333-3333-4333-8333-333333333333"
                    )
                )
            ]
        )

        do {
            _ = try await adapter.observe(desiredState: state)
            XCTFail("Expected UUID-backed ownership mismatch rejection.")
        } catch let error as RuntimeAdapterError {
            guard case .outputParseFailed(let message) = error else {
                return XCTFail("Expected outputParseFailed, got \(error).")
            }
            XCTAssertTrue(message.contains("UUID-backed state ownership"))
        }

        let calls = await runner.recordedSpecs()
        XCTAssertTrue(calls.allSatisfy { $0.classification == .readOnly })
    }

    func testProductionObservationPropagatesCancellationWithoutPartialObservationOrFurtherCommands() async throws {
        let runner = try InventoryRuntimeProcessRunner(version: "1.1.0", cancelAtCall: 8)
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [
                    AppleContainerCommand.executableName: "/usr/local/bin/container",
                    "sw_vers": "/usr/bin/sw_vers",
                    "uname": "/usr/bin/uname"
                ]
            ),
            processRunner: runner
        )
        var observation: ObservedRuntimeState?

        do {
            observation = try await adapter.observe(
                desiredState: DesiredRuntimeState(projectName: "demo", services: [])
            )
            XCTFail("Expected cancellation to propagate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertNil(observation)
        let calls = await runner.recordedSpecs()
        XCTAssertEqual(calls.count, 9)
        XCTAssertEqual(calls.last?.arguments, ["image", "list", "--format", "json"])
        XCTAssertTrue(calls.allSatisfy { $0.classification == .readOnly })
    }

    func testProductionInventoryCollectsStatsForManagedInfrastructure() async throws {
        let projectUUID = "11111111-1111-4111-8111-111111111111"
        let infrastructureIdentity = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "hostwright-dns"
        )
        let infrastructureID =
            infrastructureIdentity.managedResourceIdentifier
        let dnsUUID = HostwrightResourceUUID.legacy(
            kind: "project-dns",
            identifier: projectUUID
        )
        let fencingToken = "33333333-3333-4333-8333-333333333333"
        let infrastructureLabels = try RuntimeManagedResourceIdentity.labels(
            for: infrastructureIdentity,
            context: RuntimeMutationContext(
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "a", count: 64),
                operationID: "inventory-dns-infra-test",
                resourceUUID: dnsUUID,
                resourceGeneration: 2,
                projectResourceUUID: projectUUID,
                projectGeneration: 3,
                providerGeneration: 4,
                fencingToken: fencingToken
            )
        ).merging(
            try RuntimeProjectDNSContract.infrastructureLabels(projectUUID: projectUUID)
        ) { current, _ in current }
        let runner = try InventoryRuntimeProcessRunner(
            version: "1.1.0",
            additionalContainers: [
                try inventoryContainerJSON(
                    id: infrastructureID,
                    imageReference: CoreDNSInfrastructureImage.immutableLinuxARM64Reference,
                    labels: infrastructureLabels,
                    state: "running"
                )
            ]
        )
        let adapter = AppleContainerReadOnlyAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [
                    AppleContainerCommand.executableName: "/usr/local/bin/container",
                    "sw_vers": "/usr/bin/sw_vers",
                    "uname": "/usr/bin/uname"
                ]
            ),
            processRunner: runner
        )

        _ = try await adapter.inventory()

        let calls = await runner.recordedSpecs()
        XCTAssertTrue(calls.contains {
            $0.arguments == [
                "stats",
                infrastructureID,
                "--no-stream",
                "--format",
                "json"
            ]
        })
    }
}

private actor InventoryRuntimeProcessRunner: RuntimeProcessRunning {
    private let versionOutput: String
    private let statusOutput: String
    private let containersOutput: String
    private let imagesOutput: String
    private let networksOutput: String
    private let volumesOutput: String
    private let machinesOutput: String
    private let statsOutput: String
    private let statsByContainerID: [String: String]
    private let cancelAtCall: Int?
    private var specs: [RuntimeCommandSpec] = []

    init(
        version: String,
        cancelAtCall: Int? = nil,
        additionalContainers: [[String: Any]] = []
    ) throws {
        versionOutput = try Self.fixture("apple-container-\(version)-version.txt")
        statusOutput = try Self.fixture("apple-container-\(version)-system-status.json")
        let baseContainersText = try Self.fixture("apple-container-\(version)-inventory-containers.json")
        if additionalContainers.isEmpty {
            containersOutput = baseContainersText
        } else {
            let baseContainers = try Self.containers(from: baseContainersText)
            let merged = baseContainers + additionalContainers
            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            containersOutput = String(decoding: data, as: UTF8.self)
        }
        imagesOutput = try Self.fixture("apple-container-\(version)-image-list.json")
        networksOutput = try Self.fixture("apple-container-\(version)-network-list.json")
        volumesOutput = try Self.fixture("apple-container-\(version)-volume-list.json")
        machinesOutput = try Self.fixture("apple-container-\(version)-machine-list.json")
        let statsFixture = try Self.fixture("apple-container-\(version)-stats.json")
        statsOutput = statsFixture
        let mergedContainers = try Self.containers(from: containersOutput)
        var statsByContainerID: [String: String] = [:]
        for container in mergedContainers {
            guard let id = container["id"] as? String else { continue }
            statsByContainerID[id] = try Self.statsPayload(
                from: statsFixture,
                containerID: id
            )
        }
        self.statsByContainerID = statsByContainerID
        self.cancelAtCall = cancelAtCall
    }

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        let call = specs.count
        specs.append(spec)
        if call == cancelAtCall {
            throw CancellationError()
        }
        let output: String
        if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["--version"] {
            output = versionOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["system", "status", "--format", "json"] {
            output = statusOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["list", "--all", "--format", "json"] {
            output = containersOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["image", "list", "--format", "json"] {
            output = imagesOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["network", "list", "--format", "json"] {
            output = networksOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["volume", "list", "--format", "json"] {
            output = volumesOutput
        } else if spec.executablePath == "/usr/local/bin/container" && spec.arguments == ["machine", "list", "--format", "json"] {
            output = machinesOutput
        } else if spec.executablePath == "/usr/local/bin/container",
                  spec.arguments.count == 5,
                  spec.arguments.first == "stats",
                  Array(spec.arguments.dropFirst(2)) == ["--no-stream", "--format", "json"] {
            guard let containerID = spec.arguments.dropFirst().first,
                  let stats = statsByContainerID[containerID] else {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "Unexpected stats target."
                )
            }
            output = stats
        } else if spec.executablePath == "/usr/bin/sw_vers" && spec.arguments == ["-productVersion"] {
            output = "26.0\n"
        } else if spec.executablePath == "/usr/bin/sw_vers" && spec.arguments == ["-buildVersion"] {
            output = "25A1\n"
        } else if spec.executablePath == "/usr/bin/uname" && spec.arguments == ["-m"] {
            output = "arm64\n"
        } else {
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Unexpected inventory command."
            )
        }
        return RuntimeCommandResult(
            spec: spec,
            exitStatus: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    func recordedSpecs() -> [RuntimeCommandSpec] {
        specs
    }

    private static func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func containers(from text: String) throws -> [[String: Any]] {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let containers = object as? [[String: Any]] else {
            throw RuntimeAdapterError.outputParseFailed(
                "Inventory test fixture did not contain a container array."
            )
        }
        return containers
    }

    private static func statsPayload(
        from text: String,
        containerID: String
    ) throws -> String {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard var records = object as? [[String: Any]],
              records.count == 1 else {
            throw RuntimeAdapterError.outputParseFailed(
                "Inventory stats fixture did not contain one record."
            )
        }
        records[0]["id"] = containerID
        let encoded = try JSONSerialization.data(
            withJSONObject: records,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: encoded, as: UTF8.self)
    }
}

private func inventoryContainerJSON(
    id: String,
    imageReference: String,
    labels: [String: String],
    state: String
) throws -> [String: Any] {
    let labelsJSON = try jsonString(labels)
    let payload = """
    {
      "id": "\(id)",
      "configuration": {
        "id": "\(id)",
        "creationDate": "2026-07-26T23:10:00Z",
        "labels": \(labelsJSON),
        "publishedPorts": [],
        "mounts": [],
        "networks": [
          {
            "network": "default",
            "options": {
              "hostname": "\(id)"
            }
          }
        ],
        "platform": {
          "architecture": "arm64",
          "os": "linux"
        },
        "image": {
          "reference": "\(imageReference)",
          "descriptor": {
            "digest": "sha256:d5cc132a34e034ecfd2d4c73c5bf341e5d8af9a0ba46bd7619d9448beb27e7a2",
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "size": 369
          }
        },
        "initProcess": {
          "executable": "/coredns",
          "arguments": ["-conf", "/etc/coredns/Corefile"],
          "environment": [
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          ],
          "workingDirectory": "/",
          "user": {
            "raw": {
              "userString": "nonroot:nonroot"
            }
          },
          "terminal": false,
          "rlimits": [],
          "supplementalGroups": []
        },
        "resources": {
          "cpuOverhead": 1,
          "cpus": 4,
          "memoryInBytes": 1073741824
        },
        "capAdd": [],
        "capDrop": [],
        "publishedSockets": [],
        "readOnly": false,
        "rosetta": false,
        "runtimeHandler": "container-runtime-linux",
        "ssh": false,
        "sysctls": {},
        "useInit": false,
        "virtualization": false
      },
      "status": {
        "state": "\(state)",
        "startedDate": "2026-07-26T23:10:05Z",
        "networks": [
          {
            "network": "default",
            "hostname": "\(id)",
            "ipv4Address": "192.168.64.10/24",
            "ipv4Gateway": "192.168.64.1",
            "ipv6Address": "fdae:498:8db7:d30c:f00d:cafe:beef:10/64",
            "macAddress": "f2:0d:ca:fe:be:10",
            "variant": "reserved"
          }
        ]
      }
    }
    """
    let data = Data(payload.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let container = object as? [String: Any] else {
        throw RuntimeAdapterError.outputParseFailed(
            "Failed to build inventory test container JSON."
        )
    }
    return container
}

private func jsonString(_ value: [String: String]) throws -> String {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return String(decoding: data, as: UTF8.self)
}
