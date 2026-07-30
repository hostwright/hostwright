import Darwin
import Foundation
import XCTest
@testable import HostwrightRuntime

final class Phase07LocalNetworkForwardingLiveTests: XCTestCase {
    private static let liveFlag = "HOSTWRIGHT_PHASE07_GATE15_LIVE"
    private static let deniedLiveFlag = "HOSTWRIGHT_PHASE07_GATE15_DENIED_LIVE"
    private static let containerPort = 18_080
    private static let image =
        "docker.io/library/python@sha256:" +
        "26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92"

    func testAuthorizedLocalhostForwardingSurvivesCancellationRestartAndConflict() async throws {
        guard ProcessInfo.processInfo.environment[Self.liveFlag] == "1" else {
            throw XCTSkip(
                "Set \(Self.liveFlag)=1 only after explicitly granting Local Network permission."
            )
        }

        try await runForwardingProof(expectHostReachability: true)
    }

    func testDeniedLocalNetworkPermissionFailsClosedAndCleansUpExactly() async throws {
        guard ProcessInfo.processInfo.environment[Self.deniedLiveFlag] == "1" else {
            throw XCTSkip(
                "Set \(Self.deniedLiveFlag)=1 only on the explicit denied-permission live cell."
            )
        }
        guard ProcessInfo.processInfo.environment[Self.liveFlag] != "1" else {
            throw Gate15Failure.conflictingPermissionCells
        }

        try await runForwardingProof(expectHostReachability: false)
    }

    private func runForwardingProof(expectHostReachability: Bool) async throws {
        let adapter = AppleContainerApplyAdapter()
        let capabilities = try await adapter.capabilitySnapshot()
        let runtimeVersion = try await adapter.runtimeVersion()
        guard runtimeVersion.hasPrefix("1.0.") || runtimeVersion.hasPrefix("1.1.") else {
            throw Gate15Failure.unsupportedRuntime(runtimeVersion)
        }
        let imageEvidence = try await adapter.localImageEvidence(for: Self.image)
        guard imageEvidence.descriptorDigest ==
            "sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92" else {
            throw Gate15Failure.localImageDigestMismatch
        }

        let before = try await adapter.inventory()
        let proofUUID = Self.uuid()
        let occupiedRuntimePorts = Set(
            before.containers.flatMap { $0.ports.compactMap(\.hostPort) }
        )
        let hostPort = try Self.collisionCheckedHighPort(
            seed: proofUUID,
            excluding: occupiedRuntimePorts
        )
        let projectUUID = Self.uuid()
        let primary = try liveContainer(
            suffix: String(proofUUID.prefix(8)),
            role: "server",
            projectUUID: projectUUID,
            resourceUUID: proofUUID,
            capabilitySHA256: capabilities.canonicalSHA256,
            hostPort: hostPort
        )
        let conflicting = try liveContainer(
            suffix: String(proofUUID.prefix(8)),
            role: "conflict",
            projectUUID: projectUUID,
            resourceUUID: Self.uuid(),
            capabilitySHA256: capabilities.canonicalSHA256,
            hostPort: hostPort
        )
        let resources = [conflicting, primary]
        var bodyError: Error?

        do {
            try await createAndStart(primary, using: adapter)
            if expectHostReachability {
                try await requireExactResponse(port: hostPort, path: "/")
                try await requireCancellationDoesNotBreakForwarding(port: hostPort)
                try await requirePortConflict(
                    conflicting,
                    owner: primary,
                    port: hostPort,
                    using: adapter
                )
                try await restart(primary, using: adapter)
                try await requireExactResponse(port: hostPort, path: "/")
            } else {
                try await requireDeniedResponse(port: hostPort)
            }
        } catch {
            bodyError = error
        }

        let cleanupFailures = await cleanup(resources: resources, using: adapter)
        let after = try await adapter.inventory()
        XCTAssertEqual(
            after.semanticSHA256,
            before.semanticSHA256,
            "Gate 15 cleanup changed the pre-existing Apple runtime inventory."
        )
        XCTAssertEqual(
            Set(after.containers.map(\.runtimeID)),
            Set(before.containers.map(\.runtimeID)),
            "Gate 15 cleanup changed a pre-existing runtime identifier."
        )
        if !cleanupFailures.isEmpty {
            XCTFail("Gate 15 exact cleanup failed: \(cleanupFailures.joined(separator: "; "))")
        }
        if let bodyError {
            throw bodyError
        }
        if !cleanupFailures.isEmpty {
            throw Gate15Failure.cleanupFailed
        }
    }

    private func liveContainer(
        suffix: String,
        role: String,
        projectUUID: String,
        resourceUUID: String,
        capabilitySHA256: String,
        hostPort: Int
    ) throws -> Gate15LiveContainer {
        let identity = RuntimeServiceIdentity(
            projectName: "phase07-gate15-\(suffix)",
            serviceName: role
        )
        let service = DesiredRuntimeService(
            identity: identity,
            image: Self.image,
            command: [
                "python3",
                "-u",
                "-c",
                Self.serverProgram
            ],
            ports: [
                RuntimePortMapping(
                    hostPort: hostPort,
                    containerPort: Self.containerPort,
                    bindAddress: "127.0.0.1"
                )
            ]
        )
        return Gate15LiveContainer(
            service: service,
            context: RuntimeMutationContext(
                providerID: .appleContainerCLI,
                capabilitySHA256: capabilitySHA256,
                operationID: "phase07-gate15-\(role)-\(Self.uuid())",
                resourceUUID: resourceUUID,
                resourceGeneration: 1,
                projectResourceUUID: projectUUID,
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: Self.uuid()
            )
        )
    }

    private func createAndStart(
        _ resource: Gate15LiveContainer,
        using adapter: AppleContainerApplyAdapter
    ) async throws {
        _ = try await adapter.execute(
            resource.action(
                kind: .create,
                isDestructive: false,
                summary: "Create exact Phase 07 Gate 15 localhost forwarding proof."
            ),
            confirmation: resource.confirmation
        )
        _ = try await adapter.execute(
            resource.action(
                kind: .start,
                isDestructive: false,
                summary: "Start exact Phase 07 Gate 15 localhost forwarding proof."
            ),
            confirmation: resource.confirmation
        )
    }

    private func restart(
        _ resource: Gate15LiveContainer,
        using adapter: AppleContainerApplyAdapter
    ) async throws {
        _ = try await adapter.execute(
            resource.action(
                kind: .restart,
                isDestructive: true,
                summary: "Restart exact Phase 07 Gate 15 localhost forwarding proof."
            ),
            confirmation: resource.confirmation
        )
    }

    private func requirePortConflict(
        _ conflicting: Gate15LiveContainer,
        owner: Gate15LiveContainer,
        port: Int,
        using adapter: AppleContainerApplyAdapter
    ) async throws {
        var conflictObserved = false
        do {
            try await createAndStart(conflicting, using: adapter)
        } catch {
            conflictObserved = true
        }
        guard conflictObserved else {
            throw Gate15Failure.portConflictWasAccepted(port)
        }
        let inventory = try await adapter.inventory()
        guard let ownerEvidence = inventory.containers.first(where: {
            $0.runtimeID == owner.identifier
        }), ownerEvidence.ownership == owner.ownership else {
            throw Gate15Failure.ownerLostAfterConflict
        }
        try await requireExactResponse(port: port, path: "/")
    }

    private func requireExactResponse(port: Int, path: String) async throws {
        let result = try await waitForHTTP(port: port, path: path)
        guard result.statusCode == 200,
              result.body == Data(Self.expectedResponse.utf8) else {
            throw Gate15Failure.unexpectedHTTPResponse(
                status: result.statusCode,
                body: String(decoding: result.body, as: UTF8.self)
            )
        }
    }

    private func requireCancellationDoesNotBreakForwarding(port: Int) async throws {
        let url = try Self.url(port: port, path: "/slow")
        let request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        let task = Task {
            try await URLSession.shared.data(for: request)
        }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        do {
            _ = try await task.value
            throw Gate15Failure.cancelledRequestCompleted
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        }
        try await requireExactResponse(port: port, path: "/")
    }

    private func requireDeniedResponse(port: Int) async throws {
        do {
            _ = try await waitForHTTP(port: port, path: "/", attempts: 3)
            throw Gate15Failure.deniedPermissionAllowedForwarding
        } catch Gate15Failure.deniedPermissionAllowedForwarding {
            throw Gate15Failure.deniedPermissionAllowedForwarding
        } catch {
        }
    }

    private func waitForHTTP(
        port: Int,
        path: String,
        attempts: Int = 20
    ) async throws -> Gate15HTTPResponse {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let url = try Self.url(port: port, path: path)
                let request = URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: 2
                )
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw Gate15Failure.nonHTTPResponse
                }
                return Gate15HTTPResponse(statusCode: http.statusCode, body: data)
            } catch {
                lastError = error
            }
            if attempt < attempts {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw lastError ?? Gate15Failure.forwardingTimedOut
    }

    private func cleanup(
        resources: [Gate15LiveContainer],
        using adapter: AppleContainerApplyAdapter
    ) async -> [String] {
        var failures: [String] = []
        for resource in resources {
            do {
                let inventory = try await adapter.inventory()
                guard let evidence = inventory.containers.first(where: {
                    $0.runtimeID == resource.identifier
                }) else {
                    continue
                }
                guard evidence.ownership == resource.ownership else {
                    failures.append(
                        "refused cleanup after ownership mismatch: \(resource.identifier)"
                    )
                    continue
                }
                if evidence.lifecycle == .running {
                    _ = try await adapter.execute(
                        resource.action(
                            kind: .stop,
                            isDestructive: true,
                            summary: "Stop exact owned Phase 07 Gate 15 resource."
                        ),
                        confirmation: resource.confirmation
                    )
                }
                _ = try await adapter.execute(
                    resource.action(
                        kind: .remove,
                        isDestructive: true,
                        summary: "Remove exact owned Phase 07 Gate 15 resource."
                    ),
                    confirmation: resource.confirmation
                )
            } catch {
                failures.append("\(resource.identifier): \(error)")
            }
        }
        return failures
    }

    private static func collisionCheckedHighPort(
        seed: String,
        excluding occupiedRuntimePorts: Set<Int>
    ) throws -> Int {
        let seedPrefix = String(seed.replacingOccurrences(of: "-", with: "").prefix(8))
        let offset = Int(seedPrefix, radix: 16) ?? 0
        let range = 49_152...65_535
        let start = range.lowerBound + offset % range.count
        for index in 0..<range.count {
            let candidate =
                range.lowerBound + (start - range.lowerBound + index) % range.count
            if !occupiedRuntimePorts.contains(candidate),
               canBindLoopback(port: candidate) {
                return candidate
            }
        }
        throw Gate15Failure.noCollisionFreeHighPort
    }

    private static func canBindLoopback(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        } == 0
    }

    private static func url(port: Int, path: String) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw Gate15Failure.invalidURL
        }
        return url
    }

    private static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    private static let expectedResponse = "hostwright-phase07-local-network-ok"
    private static let serverProgram = """
    import time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/slow":
                time.sleep(10)
            body = b"hostwright-phase07-local-network-ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, format, *args):
            pass

    ThreadingHTTPServer(("0.0.0.0", 18080), Handler).serve_forever()
    """
}

private struct Gate15LiveContainer: Sendable {
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

    var confirmation: RuntimeMutationConfirmation {
        RuntimeMutationConfirmation(
            confirmed: true,
            reason: "Explicit Phase 07 Gate 15 live forwarding proof.",
            planHash: String(repeating: "f", count: 64),
            context: context
        )
    }

    func action(
        kind: PlannedRuntimeActionKind,
        isDestructive: Bool,
        summary: String
    ) -> PlannedRuntimeAction {
        PlannedRuntimeAction(
            kind: kind,
            identity: service.identity,
            resourceIdentifier: identifier,
            isDestructive: isDestructive,
            summary: summary,
            desiredService: service
        )
    }
}

private struct Gate15HTTPResponse {
    let statusCode: Int
    let body: Data
}

private enum Gate15Failure: Error {
    case cancelledRequestCompleted
    case cleanupFailed
    case conflictingPermissionCells
    case deniedPermissionAllowedForwarding
    case forwardingTimedOut
    case invalidURL
    case localImageDigestMismatch
    case noCollisionFreeHighPort
    case nonHTTPResponse
    case ownerLostAfterConflict
    case portConflictWasAccepted(Int)
    case unexpectedHTTPResponse(status: Int, body: String)
    case unsupportedRuntime(String)
}
