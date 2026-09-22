import Foundation
import HostwrightTestSupport
import Network
import XCTest
@testable import HostwrightCore
@testable import HostwrightRuntime

final class HostwrightRuntimeTests: XCTestCase {
    var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "demo", serviceName: "api")
    }

    var desiredState: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [
                desiredService
            ]
        )
    }

    var desiredStateWithExactOwnership: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "demo",
            services: [desiredService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: identity.managedResourceIdentifier,
                    identity: identity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownershipEvidence(for: inventoryFixtureMutationContext)
                )
            ]
        )
    }

    var desiredService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:latest",
            command: ["serve"],
            environment: [RuntimeEnvironmentValue(name: "APP_ENV", value: "development")],
            ports: [RuntimePortMapping(hostPort: 8080, containerPort: 8080)]
        )
    }

    var mutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "operation-create-test",
            resourceUUID: "11111111-1111-4111-8111-111111111111",
            resourceGeneration: 1,
            projectResourceUUID: "22222222-2222-4222-8222-222222222222",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    var proofIdentity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(projectName: "proof", serviceName: "web")
    }

    var proofService: DesiredRuntimeService {
        DesiredRuntimeService(
            identity: proofIdentity,
            image: "hostwright-proof-web:create-only",
            ports: [RuntimePortMapping(hostPort: 18080, containerPort: 80)]
        )
    }

    var proofDesiredState: DesiredRuntimeState {
        DesiredRuntimeState(projectName: "proof", services: [proofService])
    }

    var proofDesiredStateWithExactOwnership: DesiredRuntimeState {
        DesiredRuntimeState(
            projectName: "proof",
            services: [proofService],
            ownedResourceHints: [
                RuntimeOwnedResourceHint(
                    resourceIdentifier: proofIdentity.managedResourceIdentifier,
                    identity: proofIdentity,
                    identityVersion: RuntimeManagedResourceIdentity.currentVersion,
                    ownership: ownershipEvidence(for: proofObservationMutationContext)
                )
            ]
        )
    }

    var resolvedContainer: DictionaryRuntimeExecutableResolver {
        DictionaryRuntimeExecutableResolver(
            executables: [
                "container": "/usr/bin/container-fixture",
                "sw_vers": "/usr/bin/sw_vers-fixture",
                "uname": "/usr/bin/uname-fixture"
            ]
        )
    }

    var inventoryFixtureMutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "inventory-fixture-observation",
            resourceUUID: "22222222-2222-4222-8222-222222222222",
            resourceGeneration: 2,
            projectResourceUUID: "11111111-1111-4111-8111-111111111111",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: "33333333-3333-4333-8333-333333333333"
        )
    }

    var proofObservationMutationContext: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "b", count: 64),
            operationID: "proof-fixture-observation",
            resourceUUID: "44444444-4444-4444-8444-444444444444",
            resourceGeneration: 1,
            projectResourceUUID: "55555555-5555-4555-8555-555555555555",
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "66666666-6666-4666-8666-666666666666"
        )
    }

    func mutationConfirmation(
        planHash: String = "plan-hash",
        context: RuntimeMutationContext? = nil
    ) -> RuntimeMutationConfirmation {
        RuntimeMutationConfirmation(
            confirmed: true,
            reason: "test",
            planHash: planHash,
            context: context ?? RuntimeMutationContext(
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "a", count: 64),
                operationID: "runtime-test-operation",
                resourceUUID: HostwrightResourceUUID.generate(),
                resourceGeneration: 1,
                projectResourceUUID: HostwrightResourceUUID.generate(),
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: HostwrightResourceUUID.generate()
            )
        )
    }

    func realContainerListItem(
        identity: RuntimeServiceIdentity,
        state: String,
        networks: [[String: Any]]
    ) -> [String: Any] {
        let resourceIdentifier = identity.managedResourceIdentifier
        return [
            "configuration": [
                "id": resourceIdentifier,
                "image": ["reference": "local/test:latest"],
                "labels": RuntimeManagedResourceIdentity.labels(for: identity),
                "publishedPorts": []
            ],
            "id": resourceIdentifier,
            "status": ["state": state, "networks": networks]
        ]
    }

    func containerListOutput(
        identity: RuntimeServiceIdentity,
        state: String,
        context: RuntimeMutationContext,
        startedDate: String? = nil,
        mounts: [[String: Any]] = []
    ) throws -> String {
        let resourceIdentifier = identity.managedResourceIdentifier
        var container = try structuredInventoryTemplate()[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])

        container["id"] = resourceIdentifier
        configuration["id"] = resourceIdentifier
        configuration["labels"] = try RuntimeManagedResourceIdentity.labels(
            for: identity,
            context: context
        )
        configuration["mounts"] = mounts
        configuration["networks"] = []
        configuration["publishedPorts"] = []
        image["reference"] = "local/test:latest"
        configuration["image"] = image
        status["networks"] = []
        status["state"] = state
        status["startedDate"] = startedDate
        container["configuration"] = configuration
        container["status"] = status

        return String(
            decoding: try JSONSerialization.data(withJSONObject: [container], options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    func ownershipEvidence(
        for context: RuntimeMutationContext
    ) -> RuntimeInventoryOwnershipEvidence {
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

    func appleContainerObservationRunner(
        containers: String
    ) throws -> AppleObservationRuntimeProcessRunner {
        AppleObservationRuntimeProcessRunner(
            version: try fixture("apple-container-1.1.0-version.txt"),
            status: try fixture("apple-container-1.1.0-system-status.json"),
            containers: containers,
            images: try fixture("apple-container-1.1.0-image-list.json"),
            networks: try fixture("apple-container-1.1.0-network-list.json"),
            volumes: try fixture("apple-container-1.1.0-volume-list.json"),
            machines: try fixture("apple-container-1.1.0-machine-list.json"),
            statsByContainerID: [
                identity.managedResourceIdentifier: try fixture("apple-container-1.1.0-stats.json")
            ]
        )
    }

    func structuredBuilderContainerOutput() throws -> String {
        var payload = try structuredInventoryTemplate()
        var container = payload[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])

        container["id"] = "buildkit"
        configuration["id"] = "buildkit"
        configuration["labels"] = [
            "com.apple.container.plugin": "builder",
            "com.apple.container.resource.role": "builder"
        ]
        image["reference"] = "ghcr.io/apple/container-builder-shim/builder:0.12.0"
        configuration["image"] = image
        status["state"] = "running"
        container["configuration"] = configuration
        container["status"] = status
        payload = [container]

        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    func structuredProofContainerOutput(
        publishedSockets: [[String: Any]] = []
    ) throws -> String {
        var payload = try structuredInventoryTemplate()
        var container = payload[0]
        var configuration = try XCTUnwrap(container["configuration"] as? [String: Any])
        var image = try XCTUnwrap(configuration["image"] as? [String: Any])
        var status = try XCTUnwrap(container["status"] as? [String: Any])
        let resourceIdentifier = proofIdentity.managedResourceIdentifier

        container["id"] = resourceIdentifier
        configuration["id"] = resourceIdentifier
        configuration["labels"] = try RuntimeManagedResourceIdentity.labels(
            for: proofIdentity,
            context: proofObservationMutationContext
        )
        configuration["networks"] = []
        configuration["publishedPorts"] = [[
            "containerPort": 80,
            "count": 1,
            "hostAddress": "0.0.0.0",
            "hostPort": 18080,
            "proto": "tcp"
        ]]
        configuration["publishedSockets"] = publishedSockets
        image["reference"] = "hostwright-proof-web:create-only"
        configuration["image"] = image
        status["networks"] = []
        status["state"] = "stopped"
        container["configuration"] = configuration
        container["status"] = status
        payload = [container]

        return String(
            decoding: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    func structuredInventoryTemplate() throws -> [[String: Any]] {
        let data = Data(try fixture("apple-container-1.1.0-inventory-containers.json").utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
    }

    func assertCompleteObservationMatrix(
        _ runner: AppleObservationRuntimeProcessRunner,
        expectedStatsContainerID: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expected = [
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/sw_vers-fixture -productVersion",
            "/usr/bin/sw_vers-fixture -buildVersion",
            "/usr/bin/uname-fixture -m",
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/container-fixture list --all --format json",
            "/usr/bin/container-fixture image list --format json",
            "/usr/bin/container-fixture network list --format json",
            "/usr/bin/container-fixture volume list --format json",
            "/usr/bin/container-fixture machine list --format json"
        ]
        if let expectedStatsContainerID {
            expected.append(
                "/usr/bin/container-fixture stats \(expectedStatsContainerID) --no-stream --format json"
            )
        }
        expected += [
            "/usr/bin/container-fixture --version",
            "/usr/bin/container-fixture system status --format json",
            "/usr/bin/sw_vers-fixture -productVersion",
            "/usr/bin/sw_vers-fixture -buildVersion",
            "/usr/bin/uname-fixture -m"
        ]

        XCTAssertEqual(
            runner.calls.map { "\($0.executablePath) \($0.arguments.joined(separator: " "))" },
            expected,
            file: file,
            line: line
        )
        XCTAssertTrue(
            runner.calls.allSatisfy { $0.classification == .readOnly },
            file: file,
            line: line
        )
    }

    func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func processSpec(
        executablePath: String,
        arguments: [String],
        timeout: Int = 5
    ) -> RuntimeCommandSpec {
        RuntimeCommandSpec(
            executablePath: executablePath,
            arguments: arguments,
            timeout: RuntimeCommandTimeout(seconds: timeout),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "secure process integration"
        )
    }

    final class AppleObservationRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
        private let version: String
        private let status: String
        private let containers: String
        private let images: String
        private let networks: String
        private let volumes: String
        private let machines: String
        private let statsByContainerID: [String: String]
        private(set) var calls: [RuntimeCommandSpec] = []

        init(
            version: String,
            status: String,
            containers: String,
            images: String,
            networks: String,
            volumes: String,
            machines: String,
            statsByContainerID: [String: String]
        ) {
            self.version = version
            self.status = status
            self.containers = containers
            self.images = images
            self.networks = networks
            self.volumes = volumes
            self.machines = machines
            self.statsByContainerID = statsByContainerID
        }

        func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
            try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
            calls.append(spec)

            let output: String
            switch (spec.executablePath, spec.arguments) {
            case ("/usr/bin/container-fixture", ["--version"]):
                output = version
            case ("/usr/bin/container-fixture", ["system", "status", "--format", "json"]):
                output = status
            case ("/usr/bin/container-fixture", ["list", "--all", "--format", "json"]):
                output = containers
            case ("/usr/bin/container-fixture", ["image", "list", "--format", "json"]):
                output = images
            case ("/usr/bin/container-fixture", ["network", "list", "--format", "json"]):
                output = networks
            case ("/usr/bin/container-fixture", ["volume", "list", "--format", "json"]):
                output = volumes
            case ("/usr/bin/container-fixture", ["machine", "list", "--format", "json"]):
                output = machines
            case ("/usr/bin/sw_vers-fixture", ["-productVersion"]):
                output = "26.0\n"
            case ("/usr/bin/sw_vers-fixture", ["-buildVersion"]):
                output = "25A1\n"
            case ("/usr/bin/uname-fixture", ["-m"]):
                output = "arm64\n"
            default:
                if spec.executablePath == "/usr/bin/container-fixture",
                   spec.arguments.count == 5,
                   spec.arguments.first == "stats",
                   Array(spec.arguments.dropFirst(2)) == ["--no-stream", "--format", "json"],
                   let containerID = spec.arguments.dropFirst().first,
                   let stats = statsByContainerID[containerID] {
                    output = stats
                } else {
                    throw RuntimeAdapterError.commandRejected(
                        classification: spec.classification,
                        message: "Unexpected Apple observation command."
                    )
                }
            }

            return RuntimeCommandResult(
                spec: spec,
                exitStatus: 0,
                standardOutput: output,
                standardError: ""
            )
        }
    }

    final class RoutingRuntimeProcessRunner: RuntimeProcessRunning, @unchecked Sendable {
        typealias Handler = @Sendable (RuntimeCommandSpec) throws -> RuntimeCommandResult

        private let handler: Handler
        private(set) var calls: [RuntimeCommandSpec] = []

        init(handler: @escaping Handler) {
            self.handler = handler
        }

        func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
            if spec.arguments == ["--version"] {
                return RuntimeCommandResult(
                    spec: spec,
                    exitStatus: 0,
                    standardOutput: "container CLI version 1.1.0 (build: release, commit: 5973b9c)\n",
                    standardError: ""
                )
            }
            switch spec.classification {
            case .readOnly:
                try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
            case .mutating:
                try RuntimeCommandPolicy.validateSupportedMutation(spec)
            case .forbidden, .unknown:
                throw RuntimeAdapterError.commandRejected(classification: spec.classification, message: "rejected")
            }

            do {
                let result = try handler(spec)
                calls.append(spec)
                return result
            } catch let error as RuntimeAdapterError {
                if case .commandRejected = error,
                   let output = structuredObservationFallback(for: spec) {
                    return RuntimeCommandResult(
                        spec: spec,
                        exitStatus: 0,
                        standardOutput: output,
                        standardError: ""
                    )
                }
                calls.append(spec)
                throw error
            }
        }

        private func structuredObservationFallback(for spec: RuntimeCommandSpec) -> String? {
            switch (spec.executablePath, spec.arguments) {
            case ("/usr/bin/container-fixture", ["system", "status", "--format", "json"]):
                return #"{"status":"running","apiServerVersion":"container-apiserver version 1.1.0 (build: release, commit: 5973b9c)","apiServerBuild":"release","apiServerCommit":"5973b9c","apiServerAppName":"container-apiserver"}"#
            case ("/usr/bin/sw_vers-fixture", ["-productVersion"]):
                return "26.0\n"
            case ("/usr/bin/sw_vers-fixture", ["-buildVersion"]):
                return "25A1\n"
            case ("/usr/bin/uname-fixture", ["-m"]):
                return "arm64\n"
            case ("/usr/bin/container-fixture", ["image", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["network", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["volume", "list", "--format", "json"]),
                 ("/usr/bin/container-fixture", ["machine", "list", "--format", "json"]):
                if spec.arguments.first == "image" {
                    return #"[{"id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","configuration":{"name":"local/test:latest","descriptor":{"digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}},"variants":[]}]"#
                }
                return "[]"
            default:
                if spec.executablePath == "/usr/bin/container-fixture",
                   spec.arguments.count == 5,
                   spec.arguments.first == "stats" {
                    let id = spec.arguments[1]
                    return #"[{"id":"\#(id)","cpuUsageUsec":1,"memoryUsageBytes":2,"memoryLimitBytes":3,"networkRxBytes":4,"networkTxBytes":5,"blockReadBytes":6,"blockWriteBytes":7,"numProcesses":1}]"#
                }
                return nil
            }
        }
    }

    final class ObservationFixtureSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [String]

        init(outputs: [String]) {
            self.outputs = outputs
        }

        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            return outputs.isEmpty ? "[]" : outputs.removeFirst()
        }
    }

    final class RecordingRuntimeHealthURLFetcher: RuntimeHealthURLFetching, @unchecked Sendable {
        struct Request: Equatable {
            let url: URL
            let timeout: RuntimeCommandTimeout
        }

        private let response: RuntimeHealthURLResponse?
        private let error: Error?
        private(set) var requests: [Request] = []

        init(response: RuntimeHealthURLResponse? = nil, error: Error? = nil) {
            self.response = response
            self.error = error
        }

        func fetch(url: URL, timeout: RuntimeCommandTimeout) async throws -> RuntimeHealthURLResponse {
            requests.append(Request(url: url, timeout: timeout))
            if let error {
                throw error
            }
            return response ?? RuntimeHealthURLResponse(statusCode: 200)
        }
    }
}

final class LoopbackHTTPServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "dev.hostwright.tests.loopback-http")
    let ready = DispatchSemaphore(value: 0)
    let lock = NSLock()
    let response: Data
    var startupError: String?
    var requests = 0

    init(statusCode: Int, body: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        response = Data(
            "HTTP/1.1 \(statusCode) Test\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
        )

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                lock.lock()
                startupError = String(describing: error)
                lock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw NSError(
                domain: "HostwrightRuntimeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP server did not become ready."]
            )
        }
        if let startupError {
            listener.cancel()
            throw NSError(
                domain: "HostwrightRuntimeTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: startupError]
            )
        }
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        listener.cancel()
    }

    func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] _, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            lock.lock()
            requests += 1
            lock.unlock()
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
