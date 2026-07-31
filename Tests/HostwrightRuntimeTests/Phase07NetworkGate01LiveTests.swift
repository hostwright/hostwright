import Foundation
import XCTest
@testable import HostwrightRuntime

final class Phase07NetworkGate01LiveTests: XCTestCase {
    private let image =
        "docker.io/library/python@sha256:" +
        "26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"
    private let serverPort = 18_080

    func testAppleCLIProjectNetworksIsolateAndExplicitDualAttachmentConnects() async throws {
        guard ProcessInfo.processInfo.environment["HOSTWRIGHT_PHASE07_GATE01_LIVE"] == "1" else {
            throw XCTSkip(
                "Set HOSTWRIGHT_PHASE07_GATE01_LIVE=1 on the explicit Phase 07 Gate 1 live cell."
            )
        }

        let applyAdapter = AppleContainerApplyAdapter()
        let networkAdapter = AppleContainerNetworkAdapter()
        let interactiveExecutor = AppleContainerInteractiveExecutor()
        let capabilitySnapshot = try await applyAdapter.capabilitySnapshot()
        let before = try await applyAdapter.inventory()
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let projectAUUID = Self.uuid()
        let projectBUUID = Self.uuid()
        let networkA = try RuntimeNetworkIdentity(
            logicalName: "isolated",
            projectUUID: projectAUUID
        )
        let networkB = try RuntimeNetworkIdentity(
            logicalName: "isolated",
            projectUUID: projectBUUID
        )
        let networkAContext = mutationContext(
            capabilitySHA256: capabilitySnapshot.canonicalSHA256,
            resourceUUID: networkA.resourceUUID,
            projectUUID: projectAUUID,
            operation: "network-a"
        )
        let networkBContext = mutationContext(
            capabilitySHA256: capabilitySnapshot.canonicalSHA256,
            resourceUUID: networkB.resourceUUID,
            projectUUID: projectBUUID,
            operation: "network-b"
        )

        let server = try liveContainer(
            projectName: "phase07-a-\(suffix)",
            serviceName: "server",
            projectUUID: projectAUUID,
            capabilitySHA256: capabilitySnapshot.canonicalSHA256,
            networks: [networkA],
            command: ["python3", "-u", "-c", serverProgram]
        )
        let isolatedClient = try liveContainer(
            projectName: "phase07-b-\(suffix)",
            serviceName: "isolated-client",
            projectUUID: projectBUUID,
            capabilitySHA256: capabilitySnapshot.canonicalSHA256,
            networks: [networkB],
            command: ["python3", "-c", "import time; time.sleep(86400)"]
        )
        let dualAttachedClient = try liveContainer(
            projectName: "phase07-bridge-\(suffix)",
            serviceName: "dual-client",
            projectUUID: projectAUUID,
            capabilitySHA256: capabilitySnapshot.canonicalSHA256,
            networks: [networkA, networkB],
            command: ["python3", "-c", "import time; time.sleep(86400)"]
        )
        let containers = [server, isolatedClient, dualAttachedClient]
        let networks = [
            LiveNetwork(identity: networkA, context: networkAContext),
            LiveNetwork(identity: networkB, context: networkBContext)
        ]

        var bodyError: Error?
        do {
            _ = try await networkAdapter.create(
                DesiredRuntimeNetwork(identity: networkA, mode: .nat).createRequest,
                context: networkAContext
            )
            _ = try await networkAdapter.create(
                DesiredRuntimeNetwork(identity: networkB, mode: .nat).createRequest,
                context: networkBContext
            )

            for container in containers {
                try await createAndStart(container, using: applyAdapter)
            }

            let liveInventory = try await applyAdapter.inventory()
            let serverAddress = try requireNetworkTopology(
                inventory: liveInventory,
                server: server,
                isolatedClient: isolatedClient,
                dualAttachedClient: dualAttachedClient,
                networkA: networkA,
                networkB: networkB
            )

            let dualOutput = try await waitForServerReadiness(
                from: dualAttachedClient.identifier,
                to: serverAddress,
                capabilitySnapshot: capabilitySnapshot,
                executor: interactiveExecutor
            )
            guard dualOutput == "phase07-network-ok" else {
                throw LiveTestFailure.unexpectedProbeOutput(dualOutput)
            }

            do {
                _ = try await executeProbe(
                    from: isolatedClient.identifier,
                    to: serverAddress,
                    capabilitySnapshot: capabilitySnapshot,
                    executor: interactiveExecutor
                )
                throw LiveTestFailure.crossNetworkConnectionSucceeded
            } catch LiveTestFailure.crossNetworkConnectionSucceeded {
                throw LiveTestFailure.crossNetworkConnectionSucceeded
            } catch let error as RuntimeInteractiveError {
                guard case .processFailed = error else {
                    throw error
                }
            }
        } catch {
            bodyError = error
        }

        let cleanupFailures = await cleanup(
            containers: containers.reversed(),
            networks: networks.reversed(),
            applyAdapter: applyAdapter,
            networkAdapter: networkAdapter
        )
        let after = try await applyAdapter.inventory()
        XCTAssertEqual(
            after.semanticSHA256,
            before.semanticSHA256,
            "Gate 1 cleanup changed the pre-existing semantic Apple runtime inventory."
        )
        XCTAssertEqual(
            after.networks,
            before.networks,
            "Gate 1 cleanup changed unmanaged or default Apple networks."
        )
        if !cleanupFailures.isEmpty {
            XCTFail("Gate 1 exact cleanup failed: \(cleanupFailures.joined(separator: "; "))")
        }
        if let bodyError {
            throw bodyError
        }
        if !cleanupFailures.isEmpty {
            throw LiveTestFailure.cleanupFailed
        }
    }

    private var serverProgram: String {
        "import socket;listener=socket.socket();listener.setsockopt(socket.SOL_SOCKET," +
            "socket.SO_REUSEADDR,1);listener.bind(('0.0.0.0',\(serverPort)));" +
            "listener.listen();exec(\"while True:\\n connection,_=listener.accept();" +
            "\\n connection.sendall(b'phase07-network-ok');\\n connection.close()\")"
    }

    private var clientProgram: String {
        """
        import socket
        import sys
        connection = socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2)
        sys.stdout.write(connection.recv(64).decode("ascii"))
        connection.close()
        """
    }

    private func liveContainer(
        projectName: String,
        serviceName: String,
        projectUUID: String,
        capabilitySHA256: String,
        networks: [RuntimeNetworkIdentity],
        command: [String]
    ) throws -> LiveContainer {
        let identity = RuntimeServiceIdentity(
            projectName: projectName,
            serviceName: serviceName
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image: image,
            command: command,
            networks: try networks.map {
                try RuntimeDesiredNetworkAttachment(network: $0)
            }
        )
        return LiveContainer(
            service: service,
            context: mutationContext(
                capabilitySHA256: capabilitySHA256,
                resourceUUID: Self.uuid(),
                projectUUID: projectUUID,
                operation: serviceName
            )
        )
    }

    private func createAndStart(
        _ container: LiveContainer,
        using adapter: AppleContainerApplyAdapter
    ) async throws {
        let confirmation = RuntimeMutationConfirmation(
            confirmed: true,
            reason: "Explicit Phase 07 Gate 1 live network isolation test.",
            planHash: String(repeating: "7", count: 64),
            context: container.context
        )
        _ = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .create,
                identity: container.service.identity,
                resourceIdentifier: container.identifier,
                isDestructive: false,
                summary: "Create exact Phase 07 Gate 1 live-test container.",
                desiredService: container.service
            ),
            confirmation: confirmation
        )
        _ = try await adapter.execute(
            PlannedRuntimeAction(
                kind: .start,
                identity: container.service.identity,
                resourceIdentifier: container.identifier,
                isDestructive: false,
                summary: "Start exact Phase 07 Gate 1 live-test container.",
                desiredService: container.service
            ),
            confirmation: confirmation
        )
    }

    private func requireNetworkTopology(
        inventory: RuntimeInventory,
        server: LiveContainer,
        isolatedClient: LiveContainer,
        dualAttachedClient: LiveContainer,
        networkA: RuntimeNetworkIdentity,
        networkB: RuntimeNetworkIdentity
    ) throws -> String {
        let serverEvidence = try ownedContainer(
            server,
            in: inventory
        )
        let isolatedEvidence = try ownedContainer(
            isolatedClient,
            in: inventory
        )
        let dualEvidence = try ownedContainer(
            dualAttachedClient,
            in: inventory
        )

        guard serverEvidence.networks.contains(where: {
                  $0.networkID == networkA.runtimeIdentifier
              }),
              !serverEvidence.networks.contains(where: {
                  $0.networkID == networkB.runtimeIdentifier
              }),
              isolatedEvidence.networks.contains(where: {
                  $0.networkID == networkB.runtimeIdentifier
              }),
              !isolatedEvidence.networks.contains(where: {
                  $0.networkID == networkA.runtimeIdentifier
              }),
              Set(dualEvidence.networks.map(\.networkID)).isSuperset(
                  of: [networkA.runtimeIdentifier, networkB.runtimeIdentifier]
              ) else {
            throw LiveTestFailure.networkTopologyMismatch
        }
        guard let address = serverEvidence.networks
            .first(where: { $0.networkID == networkA.runtimeIdentifier })?
            .addresses
            .map({ $0.split(separator: "/", maxSplits: 1)[0] })
            .map(String.init)
            .first(where: { $0.contains(".") && $0 != "127.0.0.1" }) else {
            throw LiveTestFailure.missingServerAddress
        }
        return address
    }

    private func ownedContainer(
        _ expected: LiveContainer,
        in inventory: RuntimeInventory
    ) throws -> RuntimeInventoryContainer {
        guard let container = inventory.containers.first(where: {
                  $0.runtimeID == expected.identifier &&
                      $0.name == expected.identifier
              }),
              container.ownership == expected.ownership else {
            throw LiveTestFailure.ownershipMismatch(expected.identifier)
        }
        return container
    }

    private func executeProbe(
        from resourceIdentifier: String,
        to address: String,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        executor: AppleContainerInteractiveExecutor,
        timeoutMilliseconds: Int = 10_000
    ) async throws -> String {
        let output = LockedOutput()
        _ = try await executor.execute(
            .exec(
                resourceIdentifier: resourceIdentifier,
                arguments: [
                    "python3",
                    "-c",
                    clientProgram,
                    address,
                    String(serverPort)
                ],
                interactive: false,
                tty: false,
                workingDirectory: nil
            ),
            capabilitySnapshot: capabilitySnapshot,
            timeoutMilliseconds: timeoutMilliseconds
        ) { frame in
            if frame.stream == .standardOutput, !frame.endOfStream {
                try output.append(frame)
            }
        }
        return output.string
    }

    private func waitForServerReadiness(
        from resourceIdentifier: String,
        to address: String,
        capabilitySnapshot: RuntimeCapabilitySnapshot,
        executor: AppleContainerInteractiveExecutor
    ) async throws -> String {
        var lastError: Error?
        for attempt in 1...5 {
            do {
                return try await executeProbe(
                    from: resourceIdentifier,
                    to: address,
                    capabilitySnapshot: capabilitySnapshot,
                    executor: executor,
                    timeoutMilliseconds: 3_000
                )
            } catch {
                lastError = error
            }
            if attempt < 5 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? LiveTestFailure.serverReadinessTimedOut
    }

    private func cleanup(
        containers: ReversedCollection<[LiveContainer]>,
        networks: ReversedCollection<[LiveNetwork]>,
        applyAdapter: AppleContainerApplyAdapter,
        networkAdapter: AppleContainerNetworkAdapter
    ) async -> [String] {
        var failures: [String] = []
        for container in containers {
            do {
                let inventory = try await applyAdapter.inventory()
                guard let evidence = inventory.containers.first(where: {
                    $0.runtimeID == container.identifier &&
                        $0.name == container.identifier
                }) else {
                    continue
                }
                guard evidence.ownership == container.ownership else {
                    failures.append(
                        "refused container cleanup after ownership mismatch: \(container.identifier)"
                    )
                    continue
                }
                let confirmation = RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "Exact Phase 07 Gate 1 live-test cleanup.",
                    planHash: String(repeating: "7", count: 64),
                    context: container.context
                )
                if evidence.lifecycle == .running {
                    _ = try await applyAdapter.execute(
                        PlannedRuntimeAction(
                            kind: .stop,
                            identity: container.service.identity,
                            resourceIdentifier: container.identifier,
                            isDestructive: true,
                            summary: "Stop exact owned Phase 07 Gate 1 live-test container."
                        ),
                        confirmation: confirmation
                    )
                }
                _ = try await applyAdapter.execute(
                    PlannedRuntimeAction(
                        kind: .remove,
                        identity: container.service.identity,
                        resourceIdentifier: container.identifier,
                        isDestructive: true,
                        summary: "Remove exact owned Phase 07 Gate 1 live-test container."
                    ),
                    confirmation: confirmation
                )
            } catch {
                failures.append("\(container.identifier): \(error)")
            }
        }

        for network in networks {
            do {
                let inspection = try await networkAdapter.inspect(
                    RuntimeNetworkInspectRequest(identity: network.identity)
                )
                guard inspection.observedNetwork?.ownership == network.ownership else {
                    failures.append(
                        "refused network cleanup after ownership mismatch: \(network.identity.runtimeIdentifier)"
                    )
                    continue
                }
                _ = try await networkAdapter.delete(
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
        capabilitySHA256: String,
        resourceUUID: String,
        projectUUID: String,
        operation: String
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: capabilitySHA256,
            operationID: "phase07-gate01-\(operation)-\(Self.uuid())",
            resourceUUID: resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: Self.uuid()
        )
    }

    private static func uuid() -> String {
        UUID().uuidString.lowercased()
    }
}

private struct LiveContainer: Sendable {
    let service: DesiredRuntimeService
    let context: RuntimeMutationContext

    var identifier: String {
        service.identity.managedResourceIdentifier
    }

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

private enum LiveTestFailure: Error {
    case cleanupFailed
    case crossNetworkConnectionSucceeded
    case missingServerAddress
    case networkTopologyMismatch
    case ownershipMismatch(String)
    case serverReadinessTimedOut
    case unexpectedProbeOutput(String)
}

private final class LockedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ frame: RuntimeStreamEnvelope) throws {
        guard let chunk = Data(base64Encoded: frame.payloadBase64) else {
            throw RuntimeInteractiveError.invalidStreamFrame
        }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
