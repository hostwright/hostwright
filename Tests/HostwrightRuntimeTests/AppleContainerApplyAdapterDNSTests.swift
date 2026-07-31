import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightCore
@testable import HostwrightNetworking
@testable import HostwrightRuntime

final class AppleContainerApplyAdapterDNSTests: XCTestCase {
    func testAdapterResolvesExactCoreDNSAddressesOnSharedNetwork() async throws {
        let harness = try DNSApplyHarness(
            coreProjectGeneration: 3
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: harness.executableResolver,
            processRunner: harness.runner
        )

        let event = try await adapter.execute(
            harness.action,
            confirmation: harness.confirmation
        )

        let arguments = try XCTUnwrap(
            harness.runner.createArguments()
        )
        XCTAssertEqual(
            values(for: "--dns", in: arguments),
            ["10.44.0.53", "fd00:44::53"]
        )
        XCTAssertEqual(
            values(for: "--dns-search", in: arguments),
            [harness.zone]
        )
        XCTAssertEqual(
            values(for: "--network", in: arguments),
            [harness.network.runtimeIdentifier]
        )
        XCTAssertEqual(
            event.resourceIdentifier,
            harness.serviceIdentity.managedResourceIdentifier
        )
    }

    func testAdapterRejectsCoreDNSFromStaleProjectGenerationBeforeCreate() async throws {
        let harness = try DNSApplyHarness(
            coreProjectGeneration: 2
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: harness.executableResolver,
            processRunner: harness.runner
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.execute(
                harness.action,
                confirmation: harness.confirmation
            )
        )
        XCTAssertNil(harness.runner.createArguments())
    }

    func testAdapterRejectsCoreDNSWithoutSharedNetworkBeforeCreate() async throws {
        let harness = try DNSApplyHarness(
            coreProjectGeneration: 3,
            coreNetworkID: "default"
        )
        let adapter = AppleContainerApplyAdapter(
            executableResolver: harness.executableResolver,
            processRunner: harness.runner
        )

        await XCTAssertThrowsErrorAsync(
            try await adapter.execute(
                harness.action,
                confirmation: harness.confirmation
            )
        )
        XCTAssertNil(harness.runner.createArguments())
    }

    private func values(
        for flag: String,
        in arguments: [String]
    ) -> [String] {
        arguments.indices.compactMap { index in
            guard arguments[index] == flag else { return nil }
            let valueIndex = arguments.index(after: index)
            return arguments.indices.contains(valueIndex)
                ? arguments[valueIndex]
                : nil
        }
    }
}

private struct DNSApplyHarness {
    let projectUUID =
        "11111111-1111-4111-8111-111111111111"
    let serviceResourceUUID =
        "22222222-2222-4222-8222-222222222222"
    let serviceFence =
        "33333333-3333-4333-8333-333333333333"
    let coreFence =
        "44444444-4444-4444-8444-444444444444"

    let serviceIdentity = RuntimeServiceIdentity(
        projectName: "proof",
        serviceName: "api"
    )
    let coreIdentity = RuntimeServiceIdentity(
        projectName: "proof",
        serviceName: "dns"
    )
    let network: RuntimeNetworkIdentity
    let service: DesiredRuntimeService
    let context: RuntimeMutationContext
    let action: PlannedRuntimeAction
    let confirmation: RuntimeMutationConfirmation
    let runner: DNSApplyRuntimeRunner

    var zone: String {
        "\(projectUUID).hostwright.internal"
    }

    var executableResolver: DictionaryRuntimeExecutableResolver {
        DictionaryRuntimeExecutableResolver(
            executables: [
                "container": "/usr/bin/container-fixture",
                "sw_vers": "/usr/bin/sw_vers-fixture",
                "uname": "/usr/bin/uname-fixture"
            ]
        )
    }

    init(
        coreProjectGeneration: Int,
        coreNetworkID: String? = nil
    ) throws {
        let networkUUID =
            HostwrightNetworkIdentity.resourceUUID(
                projectUUID: projectUUID,
                networkName: "backend"
            )
        network = try RuntimeNetworkIdentity(
            logicalName: "backend",
            resourceUUID: networkUUID,
            projectUUID: projectUUID
        )
        context = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "dns-adapter-test",
            resourceUUID: serviceResourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken: serviceFence
        )
        service = DesiredRuntimeService(
            identity: serviceIdentity,
            image: "ghcr.io/example/api:1.1.0",
            labels:
                try RuntimeProjectDNSContract.workloadLabels(
                    projectUUID: projectUUID
                ),
            networks: [
                try RuntimeDesiredNetworkAttachment(
                    network: network
                )
            ]
        )
        action = PlannedRuntimeAction(
            kind: .create,
            identity: serviceIdentity,
            resourceIdentifier:
                serviceIdentity.managedResourceIdentifier,
            isDestructive: false,
            summary: "create with project DNS",
            desiredService: service
        )
        confirmation = RuntimeMutationConfirmation(
            confirmed: true,
            reason: "test",
            planHash: "dns-plan",
            context: context
        )

        let requirement = try XCTUnwrap(
            RuntimeProjectDNSContract.requirement(
                from: service.labels,
                projectUUID: projectUUID
            )
        )
        let coreContext = RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: context.capabilitySHA256,
            operationID: "dns-infrastructure-test",
            resourceUUID: requirement.resourceUUID,
            resourceGeneration: 1,
            projectResourceUUID: projectUUID,
            projectGeneration: coreProjectGeneration,
            providerGeneration: context.providerGeneration,
            fencingToken: coreFence
        )
        var coreLabels = try RuntimeManagedResourceIdentity.labels(
            for: coreIdentity,
            context: coreContext
        )
        coreLabels.merge(
            try RuntimeProjectDNSContract.infrastructureLabels(
                projectUUID: projectUUID
            )
        ) { current, _ in current }

        let coreContainer = try Self.container(
            identity: coreIdentity,
            image:
                CoreDNSInfrastructureImage
                    .immutableLinuxARM64Reference,
            labels: coreLabels,
            networkID: coreNetworkID ?? network.runtimeIdentifier,
            ipv4Address: "10.44.0.53/24",
            ipv6Address: "fd00:44::53/64",
            state: "running"
        )
        let createdContainer = try Self.container(
            identity: serviceIdentity,
            image: service.image,
            labels:
                try RuntimeManagedResourceIdentity.labels(
                    for: serviceIdentity,
                    context: context
                ).merging(service.labels) { current, _ in current },
            networkID: network.runtimeIdentifier,
            ipv4Address: "10.44.0.9/24",
            ipv6Address: "fd00:44::9/64",
            state: "stopped"
        )
        let networkOutput = try Self.networkOutput(
            networkID: network.runtimeIdentifier
        )
        runner = try DNSApplyRuntimeRunner(
            coreContainer: coreContainer,
            createdContainer: createdContainer,
            coreContainerID:
                coreIdentity.managedResourceIdentifier,
            networkOutput: networkOutput
        )
    }

    private static func container(
        identity: RuntimeServiceIdentity,
        image: String,
        labels: [String: String],
        networkID: String,
        ipv4Address: String,
        ipv6Address: String,
        state: String
    ) throws -> [String: Any] {
        var container = try XCTUnwrap(
            try fixtureJSONArray(
                "apple-container-1.1.0-inventory-containers.json"
            ).first
        )
        var configuration = try XCTUnwrap(
            container["configuration"] as? [String: Any]
        )
        var status = try XCTUnwrap(
            container["status"] as? [String: Any]
        )
        let identifier = identity.managedResourceIdentifier

        container["id"] = identifier
        configuration["id"] = identifier
        configuration["labels"] = labels
        configuration["image"] = [
            "reference": image,
            "descriptor": [
                "digest":
                    "sha256:\(String(repeating: "c", count: 64))"
            ]
        ]
        configuration["mounts"] = []
        configuration["publishedPorts"] = []
        configuration["networks"] = [[
            "network": networkID,
            "options": [
                "hostname": identity.serviceName,
                "macAddress": "02:00:00:00:00:53",
                "mtu": 1500
            ]
        ]]
        status["state"] = state
        status["networks"] = [[
            "network": networkID,
            "hostname": identity.serviceName,
            "ipv4Address": ipv4Address,
            "ipv4Gateway": "10.44.0.1",
            "ipv6Address": ipv6Address,
            "macAddress": "02:00:00:00:00:53",
            "mtu": 1500
        ]]
        container["configuration"] = configuration
        container["status"] = status
        return container
    }

    private static func networkOutput(
        networkID: String
    ) throws -> String {
        var network = try XCTUnwrap(
            try fixtureJSONArray(
                "apple-container-1.1.0-network-list.json"
            ).first
        )
        var configuration = try XCTUnwrap(
            network["configuration"] as? [String: Any]
        )
        var status = try XCTUnwrap(
            network["status"] as? [String: Any]
        )
        network["id"] = networkID
        configuration["name"] = networkID
        configuration["labels"] = [:]
        status["ipv4Gateway"] = "10.44.0.1"
        status["ipv4Subnet"] = "10.44.0.0/24"
        status["ipv6Subnet"] = "fd00:44::/64"
        network["configuration"] = configuration
        network["status"] = status
        return try jsonString([network])
    }

    fileprivate static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name,
                withExtension: nil
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func fixtureJSONArray(
        _ name: String
    ) throws -> [[String: Any]] {
        let data = Data(try fixture(name).utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [[String: Any]]
        )
    }

    fileprivate static func jsonString(
        _ value: Any
    ) throws -> String {
        String(
            decoding: try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys]
            ),
            as: UTF8.self
        )
    }
}

private final class DNSApplyRuntimeRunner:
    RuntimeProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let coreContainer: [String: Any]
    private let createdContainer: [String: Any]
    private let coreContainerID: String
    private let networkOutput: String
    private let imageOutput: String
    private let statusOutput: String
    private let volumeOutput: String
    private let machineOutput: String
    private var didCreate = false
    private var calls: [RuntimeCommandSpec] = []

    init(
        coreContainer: [String: Any],
        createdContainer: [String: Any],
        coreContainerID: String,
        networkOutput: String
    ) throws {
        self.coreContainer = coreContainer
        self.createdContainer = createdContainer
        self.coreContainerID = coreContainerID
        self.networkOutput = networkOutput
        imageOutput = try DNSApplyHarness.fixture(
            "apple-container-1.1.0-image-list.json"
        )
        statusOutput = try DNSApplyHarness.fixture(
            "apple-container-1.1.0-system-status.json"
        )
        volumeOutput = try DNSApplyHarness.fixture(
            "apple-container-1.1.0-volume-list.json"
        )
        machineOutput = try DNSApplyHarness.fixture(
            "apple-container-1.1.0-machine-list.json"
        )
    }

    func run(
        _ spec: RuntimeCommandSpec
    ) async throws -> RuntimeCommandResult {
        let created = lock.withLock {
            calls.append(spec)
            if spec.arguments.first == "create" {
                didCreate = true
            }
            return didCreate
        }

        let output: String
        switch (spec.executablePath, spec.arguments) {
        case (
            "/usr/bin/container-fixture",
            ["--version"]
        ):
            output =
                "container CLI version 1.1.0 " +
                "(build: release, commit: 5973b9c)\n"
        case (
            "/usr/bin/container-fixture",
            ["system", "status", "--format", "json"]
        ):
            output = statusOutput
        case (
            "/usr/bin/container-fixture",
            ["image", "list", "--format", "json"]
        ):
            output = imageOutput
        case (
            "/usr/bin/container-fixture",
            ["network", "list", "--format", "json"]
        ):
            output = networkOutput
        case (
            "/usr/bin/container-fixture",
            ["volume", "list", "--format", "json"]
        ):
            output = volumeOutput
        case (
            "/usr/bin/container-fixture",
            ["machine", "list", "--format", "json"]
        ):
            output = machineOutput
        case (
            "/usr/bin/container-fixture",
            ["list", "--all", "--format", "json"]
        ):
            output = try DNSApplyHarness.jsonString(
                created
                    ? [coreContainer, createdContainer]
                    : [coreContainer]
            )
        case (
            "/usr/bin/container-fixture",
            [
                "stats", coreContainerID, "--no-stream",
                "--format", "json"
            ]
        ):
            output = try DNSApplyHarness.jsonString([[
                "id": coreContainerID,
                "cpuUsageUsec": 1,
                "memoryUsageBytes": 2,
                "memoryLimitBytes": 4,
                "networkRxBytes": 5,
                "networkTxBytes": 6,
                "blockReadBytes": 7,
                "blockWriteBytes": 8,
                "numProcesses": 1
            ]])
        case (
            "/usr/bin/sw_vers-fixture",
            ["-productVersion"]
        ):
            output = "26.0\n"
        case (
            "/usr/bin/sw_vers-fixture",
            ["-buildVersion"]
        ):
            output = "25A1\n"
        case (
            "/usr/bin/uname-fixture",
            ["-m"]
        ):
            output = "arm64\n"
        default:
            if spec.arguments.first == "create" {
                output = ""
            } else {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "Unexpected DNS apply test command."
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

    func createArguments() -> [String]? {
        lock.withLock {
            calls.first {
                $0.arguments.first == "create"
            }?.arguments
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected asynchronous expression to throw.", file: file, line: line)
    } catch {
        // Expected.
    }
}
