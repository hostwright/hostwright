import Darwin
import Foundation
import HostwrightManifest
import HostwrightNetworkHelperCore
import HostwrightNetworking
import HostwrightState
@preconcurrency import Network

private enum QualificationError: Error {
    case invalidArguments
    case invalidConfiguration
    case connectionFailed
    case responseMismatch
}

private struct QualificationConfiguration: Codable {
    let helperExecutablePath: String
    let runtimeDirectoryPath: String
    let stateDatabasePath: String
    let identity: NetworkHelperDNSIdentity
    let request: NetworkHelperTunnelRequest
}

private final class PlainEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "dev.hostwright.tunnel-qualification.echo"
    )

    init(endpoint: HostwrightTunnelEndpoint) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw QualificationError.invalidConfiguration
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: port
        )
        listener = try NWListener(using: parameters)
    }

    func run() -> Never {
        listener.newConnectionHandler = { [queue] connection in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.receive(on: connection)
                case .failed, .cancelled:
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        let lifetime = DispatchSemaphore(value: 0)
        while true {
            lifetime.wait()
        }
    }

    private static func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { data, _, complete, error in
            guard let data, !data.isEmpty else {
                if complete || error != nil {
                    connection.cancel()
                } else {
                    receive(on: connection)
                }
                return
            }
            connection.send(
                content: data,
                completion: .contentProcessed { sendError in
                    if sendError == nil, !complete, error == nil {
                        receive(on: connection)
                    } else {
                        connection.cancel()
                    }
                }
            )
        }
    }
}

private enum TCPProbe {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var readyError: NWError?
        private var sendError: NWError?
        private var response: Data?
        private var receiveError: NWError?

        func setReadyError(_ value: NWError) {
            lock.withLock { readyError = value }
        }

        func setSendError(_ value: NWError?) {
            lock.withLock { sendError = value }
        }

        func setResponse(_ data: Data?, error: NWError?) {
            lock.withLock {
                response = data
                receiveError = error
            }
        }

        func readySucceeded() -> Bool {
            lock.withLock { readyError == nil }
        }

        func sendSucceeded() -> Bool {
            lock.withLock { sendError == nil }
        }

        func responseMatches(_ expected: Data) -> Bool {
            lock.withLock {
                receiveError == nil && response == expected
            }
        }
    }

    static func roundTrip(
        endpoint: HostwrightTunnelEndpoint,
        payload: Data,
        timeoutMilliseconds: Int = 8_000
    ) throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw QualificationError.invalidConfiguration
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(
            label: "dev.hostwright.tunnel-qualification.probe"
        )
        let ready = DispatchSemaphore(value: 0)
        let state = State()
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                ready.signal()
            case .failed(let error):
                state.setReadyError(error)
                ready.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard ready.wait(
            timeout: .now() + .milliseconds(timeoutMilliseconds)
        ) == .success,
        state.readySucceeded() else {
            throw QualificationError.connectionFailed
        }

        let sent = DispatchSemaphore(value: 0)
        connection.send(
            content: payload,
            completion: .contentProcessed { error in
                state.setSendError(error)
                sent.signal()
            }
        )
        guard sent.wait(
            timeout: .now() + .milliseconds(timeoutMilliseconds)
        ) == .success,
        state.sendSucceeded() else {
            throw QualificationError.connectionFailed
        }

        let received = DispatchSemaphore(value: 0)
        connection.receive(
            minimumIncompleteLength: payload.count,
            maximumLength: max(payload.count, 64 * 1_024)
        ) { data, _, _, error in
            state.setResponse(data, error: error)
            received.signal()
        }
        guard received.wait(
            timeout: .now() + .milliseconds(timeoutMilliseconds)
        ) == .success,
        state.responseMatches(payload) else {
            throw QualificationError.responseMismatch
        }
    }
}

@main
private struct HostwrightTunnelQualificationTool {
    static func main() async {
        do {
            try await run()
        } catch {
            let diagnostic = String(
                "\(String(reflecting: type(of: error))):"
                    + "\(String(describing: error))"
            ).prefix(1_024)
            FileHandle.standardError.write(
                Data(
                    "hostwright-tunnel-qualification: "
                        .appending(String(diagnostic))
                        .appending("\n").utf8
                )
            )
            Darwin.exit(EX_SOFTWARE)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            throw QualificationError.invalidArguments
        }
        let action = arguments[0]
        let configuration = try JSONDecoder().decode(
            QualificationConfiguration.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: arguments[1]),
                options: [.mappedIfSafe]
            )
        )
        let store = SQLiteStateStore(
            path: configuration.stateDatabasePath
        )
        if !FileManager.default.fileExists(
            atPath: configuration.stateDatabasePath
        ) {
            try store.migrate()
        } else {
            try store.validateSchema()
        }
        try seedAuthority(
            store: store,
            route: configuration.request.route
        )

        if action == "echo" {
            guard let endpoint =
                    configuration.request.execution?.serviceTarget else {
                throw QualificationError.invalidConfiguration
            }
            try PlainEchoServer(endpoint: endpoint).run()
        }
        if ["setup", "reconnect", "rotate"].contains(action),
           let execution = configuration.request.execution {
            _ = try NetworkHelperTunnelCredentialPreflight.validate(
                execution: execution
            )
        }

        let client = NetworkHelperClient(
            configuration: NetworkHelperClientConfiguration(
                executableURL: URL(
                    fileURLWithPath:
                        configuration.helperExecutablePath
                ),
                runtimeDirectoryURL: URL(
                    fileURLWithPath:
                        configuration.runtimeDirectoryPath,
                    isDirectory: true
                ),
                launchTimeoutMilliseconds: 8_000,
                requestTimeoutMilliseconds: 15_000,
                helperIdleTimeoutMilliseconds: 30_000,
                stateDatabaseURL: URL(
                    fileURLWithPath:
                        configuration.stateDatabasePath
                )
            )
        )
        let result: NetworkHelperTunnelResult
        switch action {
        case "setup":
            result = try await client.setupTunnel(
                identity: configuration.identity,
                request: configuration.request
            )
        case "status":
            result = try await client.tunnelStatus(
                identity: configuration.identity,
                request: configuration.request
            )
        case "reconnect":
            result = try await client.reconnectTunnel(
                identity: configuration.identity,
                request: configuration.request
            )
        case "rotate":
            result = try await client.rotateTunnelKey(
                identity: configuration.identity,
                request: configuration.request
            )
        case "drain":
            result = try await client.drainTunnel(
                identity: configuration.identity,
                request: configuration.request
            )
        case "teardown":
            result = try await client.teardownTunnel(
                identity: configuration.identity,
                request: configuration.request
            )
        case "probe":
            guard let endpoint =
                    configuration.request.execution?
                        .localForwardEndpoint else {
                throw QualificationError.invalidConfiguration
            }
            let payload = Data(
                (arguments.count == 3
                    ? arguments[2]
                    : "hostwright-gate13").utf8
            )
            try TCPProbe.roundTrip(
                endpoint: endpoint,
                payload: payload
            )
            result = try await client.tunnelStatus(
                identity: configuration.identity,
                request: configuration.request
            )
        default:
            throw QualificationError.invalidArguments
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(
            try encoder.encode(result) + Data([0x0a])
        )
    }

    private static func seedAuthority(
        store: SQLiteStateStore,
        route: HostwrightTunnelRoute
    ) throws {
        let projectID = "qualification:\(route.projectUUID)"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        do {
            let project = try store.desiredStates.loadProject(
                id: projectID
            )
            guard project.resourceUUID == route.projectUUID,
                  project.mutationProvider == route.providerID,
                  Int64(project.providerGeneration) ==
                    route.providerGeneration else {
                throw QualificationError.invalidConfiguration
            }
        } catch StateStoreError.notFound {
            try store.desiredStates.saveManifestSnapshot(
                projectID: projectID,
                manifestPath: nil,
                manifestHash: route.desiredSHA256,
                desiredGeneration: Int(route.providerGeneration),
                manifest: HostwrightManifest(
                    version: HostwrightManifest.currentVersion,
                    project: "gate13-qualification",
                    services: []
                ),
                timestamp: timestamp,
                mutationProvider: route.providerID,
                projectResourceUUID: route.projectUUID
            )
        }

        if let group = try store.operationGroups.load(
            id: route.operationGroupID
        ) {
            guard group.status == .active,
                  group.projectID == projectID,
                  group.fencingToken == route.fencingToken,
                  group.planHash == route.desiredSHA256 else {
                throw QualificationError.invalidConfiguration
            }
            return
        }
        let group = OperationGroupRecord(
            id: route.operationGroupID,
            operationID: "gate13-\(route.routeUUID)",
            groupKind: "service-tunnel",
            projectID: projectID,
            serviceName: nil,
            plannedActionType: "connect",
            status: .active,
            groupIdempotencyKey:
                "gate13:\(route.projectUUID):\(route.routeUUID)",
            planHash: route.desiredSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-tunnel-qualification",
            lockExpiresAt: "2999-12-31T23:59:59Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted: "{}",
            fencingToken: route.fencingToken,
            intentJSONRedacted: "{}"
        )
        guard try store.operationGroups.acquire(group).acquired == group
        else {
            throw QualificationError.invalidConfiguration
        }
    }
}
