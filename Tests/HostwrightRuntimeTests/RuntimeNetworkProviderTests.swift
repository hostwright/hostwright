import Foundation
import HostwrightNetworking
import XCTest
@testable import HostwrightRuntime

final class RuntimeNetworkProviderTests: XCTestCase {
    func testDesiredNetworkUsesSharedUUIDAndRuntimeNameAuthority() throws {
        let identity = try networkIdentity()
        XCTAssertEqual(
            identity.resourceUUID,
            HostwrightNetworkIdentity.resourceUUID(
                projectUUID: projectUUID,
                networkName: "backend"
            )
        )
        XCTAssertEqual(
            identity.runtimeIdentifier,
            HostwrightNetworkIdentity.runtimeName(
                projectUUID: projectUUID,
                networkName: "backend"
            )
        )
        XCTAssertTrue(RuntimeNetworkIdentity.isRuntimeIdentifier(identity.runtimeIdentifier))

        let desired = DesiredRuntimeNetwork(
            identity: identity,
            mode: .hostOnly
        )
        XCTAssertEqual(desired.ipv4, .automatic)
        XCTAssertEqual(desired.ipv6, .automatic)

        let attachment = try RuntimeDesiredNetworkAttachment(
            network: identity,
            aliases: ["database", "db"]
        )
        XCTAssertEqual(attachment.aliases, ["database", "db"])
        XCTAssertThrowsError(
            try RuntimeDesiredNetworkAttachment(
                network: identity,
                aliases: ["db", "db"]
            )
        )

        let mismatchedIdentity = """
        {
          "networkRuntimeIdentifier": "hw-22222222222242228222222222222222",
          "networkResourceUUID": "\(identity.resourceUUID)",
          "aliases": []
        }
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RuntimeDesiredNetworkAttachment.self,
                from: Data(mismatchedIdentity.utf8)
            )
        )
    }

    func testNetworkCapabilitiesAreExactAndTruthful() {
        let cli = RuntimeNetworkProviderCapabilities.appleContainerCLI
        XCTAssertEqual(cli.providerID, .appleContainerCLI)
        XCTAssertEqual(cli.status(for: .create)?.state, .available)
        XCTAssertEqual(cli.status(for: .inspect)?.state, .available)
        XCTAssertEqual(cli.status(for: .delete)?.state, .available)
        XCTAssertEqual(cli.status(for: .attach)?.state, .unavailable)
        XCTAssertEqual(cli.status(for: .detach)?.state, .unavailable)
        XCTAssertEqual(cli.attachmentTiming, .containerCreateOnly)
        XCTAssertEqual(Set(cli.modes), [.nat, .hostOnly])
        XCTAssertEqual(Set(cli.ipv4AddressModes), [.automatic, .cidr])
        XCTAssertFalse(cli.ipv4AddressModes.contains(.disabled))

        let helper = RuntimeNetworkProviderCapabilities.appleContainerizationUnavailable
        XCTAssertTrue(helper.operations.allSatisfy { $0.state == .unavailable })
        XCTAssertEqual(helper.attachmentTiming, .unavailable)
    }

    func testAppleCommandBuildsOwnedDualStackHostOnlyNetworkAndRejectsDisabledFamily() throws {
        let identity = try networkIdentity()
        let context = mutationContext(identity: identity)
        let executable = ResolvedRuntimeExecutable(
            name: "container",
            path: "/usr/local/bin/container"
        )
        let request = RuntimeNetworkCreateRequest(
            identity: identity,
            mode: .hostOnly,
            ipv4: .cidr("10.42.0.0/24"),
            ipv6: .cidr("fd42::/64"),
            labels: ["team": "runtime"]
        )
        let spec = try AppleContainerNetworkCommand.createSpec(
            request: request,
            context: context,
            codec: .v1_1_0,
            executable: executable
        )
        XCTAssertEqual(spec.arguments.prefix(3), ["network", "create", "--internal"])
        XCTAssertEqual(spec.arguments.suffix(1), [identity.runtimeIdentifier])
        XCTAssertTrue(spec.arguments.contains("--subnet"))
        XCTAssertTrue(spec.arguments.contains("10.42.0.0/24"))
        XCTAssertTrue(spec.arguments.contains("--subnet-v6"))
        XCTAssertTrue(spec.arguments.contains("fd42::/64"))
        XCTAssertTrue(
            spec.arguments.contains(
                "\(RuntimeManagedResourceIdentity.resourceUUIDLabel)=\(identity.resourceUUID)"
            )
        )
        XCTAssertNoThrow(try RuntimeCommandPolicy.validateNetworkLifecycleMutation(spec))

        XCTAssertThrowsError(
            try AppleContainerNetworkCommand.createSpec(
                request: RuntimeNetworkCreateRequest(
                    identity: identity,
                    mode: .nat,
                    ipv4: .automatic,
                    ipv6: .disabled
                ),
                context: context,
                codec: .v1_1_0,
                executable: executable
            )
        ) { error in
            guard case RuntimeAdapterError.mutationUnavailableByPolicy = error else {
                return XCTFail("Expected fail-closed address-family policy, got \(error)")
            }
        }
    }

    func testAppleContainerCreateCarriesExactCreateTimeNetworkAttachment() throws {
        let network = try networkIdentity()
        let attachment = try RuntimeDesiredNetworkAttachment(
            network: network,
            aliases: ["backend"]
        )
        let serviceIdentity = RuntimeServiceIdentity(
            projectName: "project",
            serviceName: "service"
        )
        let service = DesiredRuntimeService(
            identity: serviceIdentity,
            image: "example.invalid/service@sha256:\(String(repeating: "a", count: 64))",
            networks: [attachment]
        )
        let context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "service/create",
            resourceUUID: "66666666-6666-4666-8666-666666666666",
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "77777777-7777-4777-8777-777777777777"
        )
        let arguments = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: service,
            mutationContext: context,
            codec: .v1_1_0
        )

        guard let networkIndex = arguments.firstIndex(of: "--network") else {
            return XCTFail("Expected create-time network attachment.")
        }
        XCTAssertEqual(arguments[networkIndex + 1], network.runtimeIdentifier)
        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateCreateMissingServiceMutation(
                RuntimeCommandSpec(
                    executablePath: "/usr/local/bin/container",
                    arguments: arguments,
                    classification: .mutating,
                    executableResolution: .resolvedByRuntimeExecutableResolver,
                    mutationKind: .createMissingService,
                    purpose: "test"
                )
            )
        )
    }

    func testAppleAdapterVerifiesCreateInspectAndDeleteThroughStructuredObservation() async throws {
        let identity = try networkIdentity()
        let runner = RecordingNetworkProcessRunner()
        let adapter = AppleContainerNetworkAdapter(
            executableResolver: FixedNetworkExecutableResolver(),
            processRunner: runner
        )
        let request = RuntimeNetworkCreateRequest(
            identity: identity,
            mode: .nat,
            ipv4: .cidr("10.42.0.0/24"),
            ipv6: .cidr("fd42::/64")
        )
        let context = mutationContext(identity: identity)

        let created = try await adapter.create(request, context: context)
        XCTAssertEqual(created.state, .present)
        XCTAssertEqual(created.observedNetwork?.ownership?.resourceUUID, identity.resourceUUID)
        XCTAssertTrue(created.verified)

        let inspected = try await adapter.inspect(.init(identity: identity))
        XCTAssertEqual(inspected.observedNetwork?.addresses, [
            "10.42.0.0/24", "10.42.0.1", "fd42::/64"
        ])

        let deleted = try await adapter.delete(
            RuntimeNetworkDeleteRequest(identity: identity),
            context: context
        )
        XCTAssertEqual(deleted.state, .missing)
        XCTAssertTrue(deleted.verified)

        let operations = await runner.operations()
        XCTAssertEqual(
            operations,
            ["version", "create", "inspect", "version", "inspect", "version", "inspect", "delete", "list"]
        )
    }

    func testAppleAdapterRejectsMutableAttachAndDetachWithoutExecuting() async throws {
        let network = try networkIdentity()
        let request = try RuntimeNetworkAttachmentRequest(
            attachmentUUID: "33333333-3333-4333-8333-333333333333",
            network: network,
            containerRuntimeIdentifier:
                "hostwright-v2-project-service-0123456789abcdef0123456789abcdef",
            containerResourceUUID: "44444444-4444-4444-8444-444444444444"
        )
        let adapter = AppleContainerNetworkAdapter(
            executableResolver: FixedNetworkExecutableResolver(),
            processRunner: RecordingNetworkProcessRunner()
        )
        let context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "network/attach",
            resourceUUID: request.attachmentUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "55555555-5555-4555-8555-555555555555"
        )

        await XCTAssertThrowsErrorAsync(try await adapter.attach(request, context: context))
        await XCTAssertThrowsErrorAsync(try await adapter.detach(request, context: context))
    }

    func testAttachmentRequestDecodeRejectsMismatchedNetworkIdentity() throws {
        let network = try networkIdentity()
        let payload = """
        {
          "attachmentUUID": "33333333-3333-4333-8333-333333333333",
          "networkRuntimeIdentifier": "hw-22222222222242228222222222222222",
          "networkResourceUUID": "\(network.resourceUUID)",
          "containerRuntimeIdentifier": "hostwright-v2-project-service-0123456789abcdef0123456789abcdef",
          "containerResourceUUID": "44444444-4444-4444-8444-444444444444"
        }
        """

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RuntimeNetworkAttachmentRequest.self,
                from: Data(payload.utf8)
            )
        )
    }

    private let projectUUID = "11111111-1111-4111-8111-111111111111"

    private func networkIdentity() throws -> RuntimeNetworkIdentity {
        try RuntimeNetworkIdentity(logicalName: "backend", projectUUID: projectUUID)
    }

    private func mutationContext(
        identity: RuntimeNetworkIdentity
    ) -> RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "network/create",
            resourceUUID: identity.resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: identity.projectUUID,
            projectGeneration: 1,
            providerGeneration: 1,
            fencingToken: "22222222-2222-4222-8222-222222222222"
        )
    }
}

private struct FixedNetworkExecutableResolver: RuntimeExecutableResolving {
    func resolveExecutable(named name: String) throws -> ResolvedRuntimeExecutable? {
        ResolvedRuntimeExecutable(name: name, path: "/usr/local/bin/\(name)")
    }
}

private actor RecordingNetworkProcessRunner: RuntimeProcessRunning {
    private var networkJSON: String?
    private var recordedOperations: [String] = []

    func operations() -> [String] {
        recordedOperations
    }

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        let output: String
        switch spec.arguments {
        case ["--version"]:
            recordedOperations.append("version")
            output = "container CLI version 1.1.0 (build: release, commit: 5973b9c)\n"
        case let arguments where arguments.starts(with: ["network", "create"]):
            recordedOperations.append("create")
            networkJSON = try Self.networkJSON(arguments)
            output = "\(arguments.last!)\n"
        case let arguments where arguments.starts(with: ["network", "inspect"]):
            recordedOperations.append("inspect")
            guard let networkJSON else {
                throw RuntimeAdapterError.commandFailed(
                    exitStatus: 1,
                    message: "missing",
                    standardError: ""
                )
            }
            output = networkJSON
        case let arguments where arguments.starts(with: ["network", "delete"]):
            recordedOperations.append("delete")
            networkJSON = nil
            output = ""
        case ["network", "list", "--format", "json"]:
            recordedOperations.append("list")
            output = networkJSON ?? "[]"
        default:
            throw RuntimeAdapterError.commandRejected(
                classification: spec.classification,
                message: "Unexpected test command \(spec.arguments)."
            )
        }
        return RuntimeCommandResult(
            spec: spec,
            exitStatus: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    private static func networkJSON(_ arguments: [String]) throws -> String {
        var labels: [String: String] = [:]
        var ipv4 = "192.168.64.0/24"
        var ipv6 = "fd00::/64"
        var index = 2
        while index < arguments.count - 1 {
            switch arguments[index] {
            case "--internal":
                index += 1
            case "--label":
                let pair = arguments[index + 1].split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                labels[String(pair[0])] = String(pair[1])
                index += 2
            case "--subnet":
                ipv4 = arguments[index + 1]
                index += 2
            case "--subnet-v6":
                ipv6 = arguments[index + 1]
                index += 2
            default:
                throw RuntimeAdapterError.outputParseFailed("unexpected option")
            }
        }
        let identifier = arguments.last!
        let object: [[String: Any]] = [[
            "id": identifier,
            "configuration": [
                "creationDate": "2026-07-26T00:00:00Z",
                "labels": labels,
                "mode": arguments.contains("--internal") ? "hostOnly" : "nat",
                "name": identifier,
                "options": [:],
                "plugin": "container-network-vmnet"
            ],
            "status": [
                "ipv4Gateway": Self.ipv4Gateway(ipv4),
                "ipv4Subnet": ipv4,
                "ipv6Subnet": ipv6
            ]
        ]]
        return String(
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        )!
    }

    private static func ipv4Gateway(_ subnet: String) -> String {
        let address = subnet.split(separator: "/")[0].split(separator: ".")
        return "\(address[0]).\(address[1]).\(address[2]).1"
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.", file: file, line: line)
    } catch {}
}
