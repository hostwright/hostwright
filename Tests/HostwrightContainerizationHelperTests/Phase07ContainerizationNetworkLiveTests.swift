import Containerization
import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import XCTest

@testable import HostwrightContainerizationHelper
@testable import HostwrightRuntime

final class Phase07ContainerizationNetworkLiveTests: XCTestCase {
    private static let liveFlag = "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_LIVE"
    private static let policyLiveFlag =
        "HOSTWRIGHT_PHASE07_GATE12_CONTAINERIZATION_LIVE"
    private static let assetRootVariable =
        "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_WORK_ROOT"
    private static let kernelVariable =
        "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_KERNEL_PATH"
    private static let initLayoutVariable =
        "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_VMINIT_LAYOUT_PATH"
    private static let workloadLayoutVariable =
        "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_WORKLOAD_LAYOUT_PATH"
    private static let helperVariable =
        "HOSTWRIGHT_PHASE07_GATE01_CONTAINERIZATION_HELPER_PATH"
    private static let policyWorkRootVariable =
        "HOSTWRIGHT_PHASE07_GATE12_CONTAINERIZATION_WORK_ROOT"
    private static let policyHelperVariable =
        "HOSTWRIGHT_PHASE07_GATE12_CONTAINERIZATION_HELPER_PATH"
    private static let policyLoaderVariable =
        "HOSTWRIGHT_PHASE07_GATE12_CONTAINERIZATION_POLICY_LOADER_PATH"
    private static let serverPort = 18_080
    private static let deniedServerPort = 18_081
    func testRealContainerizationNetworksIsolateAndDualAttachmentConnects() async throws {
        let environment = ProcessInfo.processInfo.environment
        let gate01 = environment[Self.liveFlag] == "1"
        let gate12 = environment[Self.policyLiveFlag] == "1"
        guard gate01 || gate12 else {
            throw XCTSkip(
                "Enable only the explicit Phase 07 Gate 1 or Gate 12 Containerization cell."
            )
        }
        guard gate01 != gate12 else {
            throw LiveFailure.ambiguousQualificationGate
        }
        try await runSignedWorkerBody(policyLive: gate12)
    }

    private func runSignedWorkerBody(policyLive: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment

        let policyLoaderURL: URL?
        if policyLive {
            policyLoaderURL = try requiredT9RegularFile(
                Self.policyLoaderVariable,
                environment: environment
            )
        } else {
            policyLoaderURL = nil
        }
        let qualificationGate = policyLive
            ? "phase07-gate12"
            : "phase07-gate01"
        let workParent = try requiredPrivateWorkDirectory(
            policyLoaderURL == nil
                ? Self.assetRootVariable
                : Self.policyWorkRootVariable,
            environment: environment,
            qualificationGate: qualificationGate
        )
        let kernelURL = try requiredT9RegularFile(
            Self.kernelVariable,
            environment: environment
        )
        let initLayoutURL = try requiredT9Directory(
            Self.initLayoutVariable,
            environment: environment
        )
        let workloadLayoutURL = try requiredT9Directory(
            Self.workloadLayoutVariable,
            environment: environment
        )
        let helperURL = try requiredQualificationExecutable(
            policyLoaderURL == nil
                ? Self.helperVariable
                : Self.policyHelperVariable,
            environment: environment,
            qualificationGate: qualificationGate
        )
        let workRoot = workParent.appendingPathComponent(
            "p07-\(Self.uuid().prefix(8))",
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: workRoot,
            withIntermediateDirectories: false
        )
        guard chmod(workRoot.path, S_IRWXU) == 0 else {
            throw LiveFailure.unsafeWorkRoot
        }
        try ContainerizationHelperStateStore.preparePrivateDirectory(workRoot)
        var removedWorkRoot = false
        defer {
            if !removedWorkRoot {
                try? FileManager.default.removeItem(at: workRoot)
            }
        }

        let dataRoot = workRoot
            .appendingPathComponent("data", isDirectory: true)
            .standardizedFileURL
        let runtimeRoot = workRoot
            .appendingPathComponent("run", isDirectory: true)
            .standardizedFileURL
        let imagesRoot = dataRoot
            .appendingPathComponent("images", isDirectory: true)
            .standardizedFileURL
        try ContainerizationHelperStateStore.preparePrivateDirectory(dataRoot)
        try ContainerizationHelperStateStore.preparePrivateDirectory(runtimeRoot)
        try ContainerizationHelperStateStore.preparePrivateDirectory(imagesRoot)

        let kernelDigest = try sha256(kernelURL)
        guard kernelDigest == ContainerizationRuntimeAssetContract.kernelSHA256 else {
            throw LiveFailure.kernelDigestMismatch
        }

        let imageStore = try ImageStore(path: imagesRoot)
        let importedImages = try await imageStore.load(from: workloadLayoutURL)
        guard importedImages.count == 1 else {
            throw LiveFailure.workloadLayoutMustContainOneImage
        }
        let workloadReference = importedImages[0].reference
        let configuration = ContainerizationHelperConfiguration(
            schema: ContainerizationHelperConfiguration.schemaVersion,
            framework: ContainerizationHelperConfiguration.frameworkVersion,
            dataRootPath: dataRoot.path,
            runtimeDirectoryPath: runtimeRoot.path,
            kernelPath: kernelURL.path,
            kernelSHA256: kernelDigest,
            initImageLayoutPath: initLayoutURL.path,
            initImageReference: ContainerizationRuntimeAssetContract.initImageReference,
            initImageDescriptorDigest:
                ContainerizationRuntimeAssetContract.initImageDescriptorDigest,
            initImageVariantDigest:
                "sha256:\(ContainerizationRuntimeAssetContract.initImageVariantDigest)",
            rootfsSizeBytes: 512 * 1_024 * 1_024,
            guestNetworkPolicyLoaderPath: policyLoaderURL?.path,
            guestNetworkPolicyLoaderSHA256:
                try policyLoaderURL.map(sha256)
        )
        let configurationURL = workRoot
            .appendingPathComponent("containerization-helper.json", isDirectory: false)
            .standardizedFileURL
        try persistConfiguration(configuration, at: configurationURL)
        let client = ContainerizationHelperClient(
            configuration: try ContainerizationHelperClientConfiguration(
                executableURL: helperURL,
                configurationURL: configurationURL,
                runtimeDirectoryURL: runtimeRoot,
                launchTimeoutMilliseconds: 60_000,
                requestTimeoutMilliseconds: 120_000
            ),
            launcher: ContainerizationHelperProcessLauncher { configuration in
                try ContainerizationHelperPOSIXLauncher.launchPrepared(
                    configuration: configuration
                )
            }
        )
        let snapshot: RuntimeCapabilitySnapshot
        let workloadImage: ContainerizationHelperImageEvidence
        let before: RuntimeInventory
        do {
            snapshot = try await client.negotiate()
            if policyLoaderURL != nil {
                let capabilities = try await client.networkCapabilities()
                XCTAssertEqual(
                    capabilities.networkPolicy?.state,
                    .available
                )
                XCTAssertEqual(
                    Set(capabilities.networkPolicy?.directions ?? []),
                    Set(HostwrightNetworkPolicyDirection.allCases)
                )
                XCTAssertEqual(
                    capabilities.networkPolicy?.appliesAtomicGenerations,
                    true
                )
                XCTAssertEqual(
                    capabilities.networkPolicy?.observesRuleDigest,
                    true
                )
            }
            workloadImage = ContainerizationHelperImageEvidence(
                try await client.localImageEvidence(workloadReference)
            )
            before = try await client.observe()
        } catch {
            await client.shutdown()
            throw error
        }

        let projectA = Self.uuid()
        let projectB = Self.uuid()
        let networkA = try RuntimeNetworkIdentity(
            logicalName: "isolated",
            projectUUID: projectA
        )
        let networkB = try RuntimeNetworkIdentity(
            logicalName: "connected",
            projectUUID: projectA
        )
        let isolatedNetwork = try RuntimeNetworkIdentity(
            logicalName: "isolated",
            projectUUID: projectB
        )
        let networkAContext = mutationContext(
            snapshot: snapshot,
            resourceUUID: networkA.resourceUUID,
            projectUUID: projectA,
            operation: "network-a"
        )
        let networkBContext = mutationContext(
            snapshot: snapshot,
            resourceUUID: networkB.resourceUUID,
            projectUUID: projectA,
            operation: "network-b"
        )
        let isolatedNetworkContext = mutationContext(
            snapshot: snapshot,
            resourceUUID: isolatedNetwork.resourceUUID,
            projectUUID: projectB,
            operation: "network-isolated"
        )
        let liveNetworks = [
            LiveNetwork(identity: networkA, context: networkAContext),
            LiveNetwork(identity: networkB, context: networkBContext),
            LiveNetwork(
                identity: isolatedNetwork,
                context: isolatedNetworkContext
            )
        ]
        var createdNetworks: [LiveNetwork] = []
        var createdContainers: [LiveContainer] = []
        var bodyError: Error?

        do {
            let createdA = try await client.networkCreate(
                RuntimeNetworkCreateRequest(
                    identity: networkA,
                    mode: .hostOnly,
                    ipv4: .cidr("192.168.240.0/24"),
                    ipv6: .cidr("fd00:7:1::/64")
                ),
                context: networkAContext
            )
            createdNetworks.append(liveNetworks[0])
            let createdB = try await client.networkCreate(
                RuntimeNetworkCreateRequest(
                    identity: networkB,
                    mode: .hostOnly,
                    ipv4: .cidr("192.168.241.0/24"),
                    ipv6: .cidr("fd00:7:2::/64")
                ),
                context: networkBContext
            )
            createdNetworks.append(liveNetworks[1])
            let createdIsolated = try await client.networkCreate(
                RuntimeNetworkCreateRequest(
                    identity: isolatedNetwork,
                    mode: .hostOnly,
                    ipv4: .cidr("192.168.242.0/24"),
                    ipv6: .cidr("fd00:7:3::/64")
                ),
                context: isolatedNetworkContext
            )
            createdNetworks.append(liveNetworks[2])
            guard createdA.observedNetwork?.addresses.first !=
                    createdB.observedNetwork?.addresses.first,
                  createdA.observedNetwork?.addresses.first !=
                    createdIsolated.observedNetwork?.addresses.first,
                  createdB.observedNetwork?.addresses.first !=
                    createdIsolated.observedNetwork?.addresses.first else {
                throw LiveFailure.networkSubnetsCollided
            }

            let server = try liveContainer(
                projectName: "gate07-a",
                serviceName: "server",
                projectUUID: projectA,
                snapshot: snapshot,
                image: workloadImage,
                networks: [networkA],
                command: Self.pythonCommand(Self.serverProgram),
                networkPolicy: policyLoaderURL.map { _ in
                    Self.serverNetworkPolicy()
                }
            )
            createdContainers.append(server)
            try await create(server, using: client)
            let serverAddresses = try serverAddresses(
                in: try await client.observe(),
                server: server,
                network: networkA
            )
            try await start(server, using: client)
            _ = try await waitForLog(
                client: client,
                resourceIdentifier: server.resourceIdentifier,
                success: "server-ready",
                failure: "server-failed"
            )

            let dualClient = try liveContainer(
                projectName: "gate07-a",
                serviceName: "dual-client",
                projectUUID: projectA,
                snapshot: snapshot,
                image: workloadImage,
                networks: [networkA, networkB],
                command: Self.pythonCommand(
                    Self.dualClientProgram,
                    arguments: [
                    serverAddresses.ipv4,
                    serverAddresses.ipv6,
                    String(Self.serverPort),
                    String(Self.deniedServerPort),
                    policyLoaderURL == nil ? "0" : "1"
                    ]
                ),
                networkPolicy: policyLoaderURL.map { _ in
                    Self.clientNetworkPolicy()
                }
            )
            createdContainers.append(dualClient)
            try await create(dualClient, using: client)
            try await start(dualClient, using: client)
            _ = try await waitForLog(
                client: client,
                resourceIdentifier: dualClient.resourceIdentifier,
                success: policyLoaderURL == nil
                    ? "dual-ok"
                    : "dual-ok-1",
                failure: "dual-failed"
            )
            if policyLoaderURL != nil {
                _ = try await client.restart(
                    ContainerizationHelperMutationPayload(
                        resourceIdentifier:
                            dualClient.resourceIdentifier,
                        resourceUUID:
                            dualClient.context.resourceUUID
                    ),
                    context: dualClient.context
                )
                _ = try await waitForLog(
                    client: client,
                    resourceIdentifier:
                        dualClient.resourceIdentifier,
                    success: "dual-ok-2",
                    failure: "dual-failed"
                )
            }

            let isolatedClient = try liveContainer(
                projectName: "gate07-b",
                serviceName: "isolated-client",
                projectUUID: projectB,
                snapshot: snapshot,
                image: workloadImage,
                networks: [isolatedNetwork],
                command: Self.pythonCommand(
                    Self.isolatedClientProgram,
                    arguments: [
                    serverAddresses.ipv4,
                    serverAddresses.ipv6,
                    String(Self.serverPort)
                    ]
                )
            )
            createdContainers.append(isolatedClient)
            try await create(isolatedClient, using: client)
            try await start(isolatedClient, using: client)
            _ = try await waitForLog(
                client: client,
                resourceIdentifier: isolatedClient.resourceIdentifier,
                success: "isolation-ok",
                failure: "isolation-failed"
            )

            let connected = try await client.observe()
            try verifyTopology(
                connected,
                server: server,
                dualClient: dualClient,
                isolatedClient: isolatedClient,
                networkA: networkA,
                networkB: networkB,
                isolatedNetwork: isolatedNetwork
            )
        } catch {
            bodyError = error
        }

        let cleanupFailures = await cleanup(
            client: client,
            containers: createdContainers.reversed(),
            networks: createdNetworks.reversed()
        )
        let after = try await client.observe()
        XCTAssertEqual(after.semanticSHA256, before.semanticSHA256)
        XCTAssertEqual(after.containers, before.containers)
        XCTAssertEqual(after.networks, before.networks)
        XCTAssertEqual(after.images, before.images)
        await client.shutdown()

        try FileManager.default.removeItem(at: workRoot)
        removedWorkRoot = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: workRoot.path))

        guard cleanupFailures.isEmpty else {
            throw LiveFailure.cleanupFailed(cleanupFailures)
        }
        if let bodyError {
            throw bodyError
        }
    }

    private func liveContainer(
        projectName: String,
        serviceName: String,
        projectUUID: String,
        snapshot: RuntimeCapabilitySnapshot,
        image: ContainerizationHelperImageEvidence,
        networks: [RuntimeNetworkIdentity],
        command: [String],
        networkPolicy: HostwrightServiceNetworkPolicy? = nil
    ) throws -> LiveContainer {
        let identity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName
        )
        let context = mutationContext(
            snapshot: snapshot,
            resourceUUID: Self.uuid(),
            projectUUID: projectUUID,
            operation: serviceName
        )
        let labels = try RuntimeManagedResourceIdentity.labels(
            for: identity,
            context: context
        ).map {
            RuntimeInventoryLabel(key: $0.key, value: $0.value)
        }
        return LiveContainer(
            resourceIdentifier:
                RuntimeManagedResourceIdentity.resourceIdentifier(for: identity),
            context: context,
            payload: ContainerizationHelperCreatePayload(
                resourceIdentifier:
                    RuntimeManagedResourceIdentity.resourceIdentifier(for: identity),
                resourceUUID: context.resourceUUID,
                projectUUID: context.projectResourceUUID,
                logicalServiceName: serviceName,
                image: image,
                command: command,
                environment: [],
                labels: labels,
                networks: try networks.map {
                    try RuntimeDesiredNetworkAttachment(network: $0)
                },
                networkPolicy: networkPolicy
            )
        )
    }

    private static func serverNetworkPolicy()
        -> HostwrightServiceNetworkPolicy {
        HostwrightServiceNetworkPolicy(
            ingress: allowedServerRules()
        )
    }

    private static func clientNetworkPolicy()
        -> HostwrightServiceNetworkPolicy {
        HostwrightServiceNetworkPolicy(
            egress: allowedServerRules()
        )
    }

    private static func allowedServerRules()
        -> [HostwrightNetworkPolicyRule] {
        [
            HostwrightNetworkPolicyRule(
                protocolName: .tcp,
                address: "192.168.240.0/24",
                port: serverPort
            ),
            HostwrightNetworkPolicyRule(
                protocolName: .tcp,
                address: "fd00:7:1::/64",
                port: serverPort
            )
        ]
    }

    private func create(
        _ container: LiveContainer,
        using client: ContainerizationHelperClient
    ) async throws {
        _ = try await client.create(container.payload, context: container.context)
    }

    private func start(
        _ container: LiveContainer,
        using client: ContainerizationHelperClient
    ) async throws {
        _ = try await client.start(
            ContainerizationHelperMutationPayload(
                resourceIdentifier: container.resourceIdentifier,
                resourceUUID: container.context.resourceUUID
            ),
            context: container.context
        )
    }

    private func serverAddresses(
        in inventory: RuntimeInventory,
        server: LiveContainer,
        network: RuntimeNetworkIdentity
    ) throws -> (ipv4: String, ipv6: String) {
        guard let container = inventory.containers.first(where: {
                  $0.name == server.resourceIdentifier
              }),
              container.ownership == server.ownership,
              let addresses = container.networks.first(where: {
                  $0.networkID == network.runtimeIdentifier
              })?.addresses,
              let ipv4 = addresses.first(where: {
                  $0.contains(".")
              })?.split(separator: "/", maxSplits: 1).first,
              let ipv6 = addresses.first(where: {
                  $0.contains(":")
              })?.split(separator: "/", maxSplits: 1).first else {
            throw LiveFailure.missingServerAddress
        }
        return (String(ipv4), String(ipv6))
    }

    private func verifyTopology(
        _ inventory: RuntimeInventory,
        server: LiveContainer,
        dualClient: LiveContainer,
        isolatedClient: LiveContainer,
        networkA: RuntimeNetworkIdentity,
        networkB: RuntimeNetworkIdentity,
        isolatedNetwork: RuntimeNetworkIdentity
    ) throws {
        let serverNetworks = try ownedContainer(server, inventory: inventory).networks
        let dualNetworks = try ownedContainer(dualClient, inventory: inventory).networks
        let isolatedNetworks = try ownedContainer(
            isolatedClient,
            inventory: inventory
        ).networks
        guard Set(serverNetworks.map(\.networkID)) == [networkA.runtimeIdentifier],
              Set(dualNetworks.map(\.networkID)) ==
                [networkA.runtimeIdentifier, networkB.runtimeIdentifier],
              Set(isolatedNetworks.map(\.networkID)) ==
                [isolatedNetwork.runtimeIdentifier] else {
            throw LiveFailure.topologyMismatch
        }
    }

    private func ownedContainer(
        _ expected: LiveContainer,
        inventory: RuntimeInventory
    ) throws -> RuntimeInventoryContainer {
        guard let container = inventory.containers.first(where: {
                  $0.name == expected.resourceIdentifier
              }),
              container.ownership == expected.ownership else {
            throw LiveFailure.ownershipMismatch(expected.resourceIdentifier)
        }
        return container
    }

    private func waitForLog(
        client: ContainerizationHelperClient,
        resourceIdentifier: String,
        success: String,
        failure: String
    ) async throws -> String {
        for attempt in 1...80 {
            let log = try await client.logs(resourceIdentifier, lineLimit: 200)
            if log.contains(failure) {
                throw LiveFailure.probeFailed(failure)
            }
            if log.contains(success) {
                return log
            }
            if attempt < 80 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw LiveFailure.probeTimedOut(success)
    }

    private func cleanup(
        client: ContainerizationHelperClient,
        containers: ReversedCollection<[LiveContainer]>,
        networks: ReversedCollection<[LiveNetwork]>
    ) async -> [String] {
        var failures: [String] = []
        for container in containers {
            do {
                let inventory = try await client.observe()
                guard inventory.containers.contains(where: {
                    $0.name == container.resourceIdentifier &&
                        $0.ownership == container.ownership
                }) else {
                    continue
                }
                _ = try await client.delete(
                    ContainerizationHelperMutationPayload(
                        resourceIdentifier: container.resourceIdentifier,
                        resourceUUID: container.context.resourceUUID
                    ),
                    context: container.context
                )
            } catch {
                failures.append("\(container.resourceIdentifier): \(error)")
            }
        }
        for network in networks {
            do {
                _ = try await client.networkDelete(
                    RuntimeNetworkDeleteRequest(identity: network.identity),
                    context: network.context
                )
            } catch {
                failures.append("\(network.identity.runtimeIdentifier): \(error)")
            }
        }
        return failures
    }

    private func mutationContext(
        snapshot: RuntimeCapabilitySnapshot,
        resourceUUID: String,
        projectUUID: String,
        operation: String
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerization,
            capabilitySHA256: snapshot.canonicalSHA256,
            operationID: "phase07-gate01-\(operation)-\(Self.uuid())",
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: Self.uuid()
        )
    }

    private func requiredPrivateWorkDirectory(
        _ variable: String,
        environment: [String: String],
        qualificationGate: String
    ) throws -> URL {
        guard let value = environment[variable],
              !value.isEmpty else {
            throw LiveFailure.missingEnvironment(variable)
        }
        let url = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        var metadata = stat()
        guard url.path == value,
              value ==
                "/Volumes/T9/hostwright/qualification/\(qualificationGate)",
              lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IRWXG | S_IRWXO | S_ISUID | S_ISGID | S_ISTXT) == 0,
              metadata.st_mode & S_IRWXU == S_IRWXU else {
            throw LiveFailure.invalidEnvironmentPath(variable)
        }
        return url
    }

    private func requiredT9Directory(
        _ variable: String,
        environment: [String: String]
    ) throws -> URL {
        let url = try requiredT9URL(variable, environment: environment)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw LiveFailure.invalidEnvironmentPath(variable)
        }
        return url
    }

    private func requiredT9RegularFile(
        _ variable: String,
        environment: [String: String]
    ) throws -> URL {
        let url = try requiredT9URL(variable, environment: environment)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            throw LiveFailure.invalidEnvironmentPath(variable)
        }
        return url
    }

    private func requiredQualificationExecutable(
        _ variable: String,
        environment: [String: String],
        qualificationGate: String
    ) throws -> URL {
        guard let value = environment[variable],
              !value.isEmpty else {
            throw LiveFailure.missingEnvironment(variable)
        }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Hostwright/qualification/\(qualificationGate)",
                isDirectory: true
            )
            .appendingPathComponent(
                "hostwright-containerization-helper",
                isDirectory: false
            )
            .standardizedFileURL
        var metadata = stat()
        guard url == expected,
              url.path == value,
              lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0,
              metadata.st_mode & S_IXUSR != 0 else {
            throw LiveFailure.invalidEnvironmentPath(variable)
        }
        return url
    }

    private func persistConfiguration(
        _ configuration: ContainerizationHelperConfiguration,
        at url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
            throw LiveFailure.unsafeConfiguration
        }
    }

    private func requiredT9URL(
        _ variable: String,
        environment: [String: String]
    ) throws -> URL {
        guard let value = environment[variable],
              !value.isEmpty else {
            throw LiveFailure.missingEnvironment(variable)
        }
        let url = URL(fileURLWithPath: value).standardizedFileURL
        guard url.path == value,
              (
                  url.path.hasPrefix("/Volumes/T9/") ||
                  url.path.hasPrefix("/var/root/hostwright-phase07-gate01/assets/")
              ) else {
            throw LiveFailure.invalidEnvironmentPath(variable)
        }
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    private static func pythonCommand(
        _ program: String,
        arguments: [String] = []
    ) -> [String] {
        let encoded = Data(program.utf8).base64EncodedString()
        return [
            "python3",
            "-u",
            "-c",
            "import base64;exec(base64.b64decode('\(encoded)'))"
        ] + arguments
    }

    private static let serverProgram = """
    import select
    import socket
    listeners = []
    for family, address in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
        for port in (18080, 18081):
            listener = socket.socket(family, socket.SOCK_STREAM)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((address, port))
            listener.listen()
            listeners.append(listener)
    print("server-ready", flush=True)
    while True:
        ready, _, _ = select.select(listeners, [], [])
        for listener in ready:
            connection, _ = listener.accept()
            connection.sendall(b"phase07-network-ok")
            connection.close()
    """

    private static let dualClientProgram = """
    import socket
    import sys
    import time
    from pathlib import Path
    for address in (sys.argv[1], sys.argv[2]):
        connected = False
        for _ in range(20):
            try:
                connection = socket.create_connection((address, int(sys.argv[3])), timeout=1)
                payload = connection.recv(64)
                connection.close()
                if payload == b"phase07-network-ok":
                    connected = True
                    break
            except OSError:
                time.sleep(0.25)
        if not connected:
            print("dual-failed", flush=True)
            raise SystemExit(7)
    if sys.argv[5] == "1":
        for address in (sys.argv[1], sys.argv[2]):
            try:
                connection = socket.create_connection((address, int(sys.argv[4])), timeout=1)
                connection.close()
                print("dual-failed-denied-port", flush=True)
                raise SystemExit(9)
            except OSError:
                pass
    marker = Path("/tmp/phase07-dual-run")
    run = int(marker.read_text()) + 1 if marker.exists() else 1
    marker.write_text(str(run))
    print(f"dual-ok-{run}", flush=True)
    while True:
        time.sleep(60)
    """

    private static let isolatedClientProgram = """
    import socket
    import sys
    import time
    for address in (sys.argv[1], sys.argv[2]):
        try:
            connection = socket.create_connection((address, int(sys.argv[3])), timeout=2)
            connection.close()
            print("isolation-failed", flush=True)
            raise SystemExit(8)
        except OSError:
            pass
    print("isolation-ok", flush=True)
    while True:
        time.sleep(60)
    """
}

private struct LiveContainer: Sendable {
    let resourceIdentifier: String
    let context: RuntimeMutationContext
    let payload: ContainerizationHelperCreatePayload

    var ownership: RuntimeInventoryOwnershipEvidence {
        RuntimeInventoryOwnershipEvidence(
            resourceUUID: context.resourceUUID,
            projectUUID: context.projectResourceUUID,
            resourceGeneration: context.resourceGeneration,
            projectGeneration: context.projectGeneration,
            providerID: context.providerID,
            providerGeneration: context.providerGeneration,
            fencingToken: context.fencingToken
        )
    }
}

private struct LiveNetwork: Sendable {
    let identity: RuntimeNetworkIdentity
    let context: RuntimeMutationContext
}

private enum LiveFailure: Error {
    case ambiguousQualificationGate
    case cleanupFailed([String])
    case invalidEnvironmentPath(String)
    case kernelDigestMismatch
    case missingEnvironment(String)
    case missingServerAddress
    case networkSubnetsCollided
    case ownershipMismatch(String)
    case probeFailed(String)
    case probeTimedOut(String)
    case topologyMismatch
    case unsafeConfiguration
    case unsafeWorkRoot
    case workloadLayoutMustContainOneImage
}
