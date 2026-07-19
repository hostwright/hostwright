import Foundation
import HostwrightTestSupport
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
    private var specs: [RuntimeCommandSpec] = []

    init(version: String) throws {
        versionOutput = try Self.fixture("apple-container-\(version)-version.txt")
        statusOutput = try Self.fixture("apple-container-\(version)-system-status.json")
        containersOutput = try Self.fixture("apple-container-\(version)-inventory-containers.json")
        imagesOutput = try Self.fixture("apple-container-\(version)-image-list.json")
        networksOutput = try Self.fixture("apple-container-\(version)-network-list.json")
        volumesOutput = try Self.fixture("apple-container-\(version)-volume-list.json")
        machinesOutput = try Self.fixture("apple-container-\(version)-machine-list.json")
        statsOutput = try Self.fixture("apple-container-\(version)-stats.json")
    }

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        specs.append(spec)
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
            output = statsOutput
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
}
