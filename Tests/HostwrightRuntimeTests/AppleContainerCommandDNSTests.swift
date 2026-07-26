import XCTest
@testable import HostwrightRuntime

final class AppleContainerCommandDNSTests: XCTestCase {
    func testCreateRendersSortedDNSArgumentsBeforeImage() throws {
        let zone =
            "11111111-1111-4111-8111-111111111111.hostwright.internal"
        let arguments = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: try serviceWithDNSLabels(),
            mutationContext: context,
            dnsServers: ["fd00:44::53", "10.44.0.53"],
            dnsSearchDomains: [zone]
        )

        XCTAssertEqual(
            values(for: "--dns", in: arguments),
            ["10.44.0.53", "fd00:44::53"]
        )
        XCTAssertEqual(
            values(for: "--dns-search", in: arguments),
            [zone]
        )
        let imageIndex = try XCTUnwrap(
            arguments.firstIndex(of: "ghcr.io/example/api:1.1.0")
        )
        XCTAssertTrue(
            flagIndices("--dns", in: arguments).allSatisfy {
                $0 < imageIndex
            }
        )
        XCTAssertTrue(
            flagIndices("--dns-search", in: arguments).allSatisfy {
                $0 < imageIndex
            }
        )
    }

    func testCreateWithoutResolutionEmitsNoDNSOptions() throws {
        let arguments = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: DesiredRuntimeService(
                identity: identity,
                image: "ghcr.io/example/api:1.1.0"
            ),
            mutationContext: context
        )

        XCTAssertFalse(arguments.contains("--dns"))
        XCTAssertFalse(arguments.contains("--dns-search"))
    }

    func testBothSupportedCodecsRenderTheSameDNSContract() throws {
        let service = try serviceWithDNSLabels()
        let zone =
            "11111111-1111-4111-8111-111111111111.hostwright.internal"

        let v10 = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: service,
            mutationContext: context,
            dnsServers: ["10.44.0.53"],
            dnsSearchDomains: [zone],
            codec: .v1_0_0
        )
        let v11 = try AppleContainerCommand.arguments(
            for: .createContainer,
            desiredService: service,
            mutationContext: context,
            dnsServers: ["10.44.0.53"],
            dnsSearchDomains: [zone],
            codec: .v1_1_0
        )

        XCTAssertEqual(v10, v11)
    }

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: "proof",
            serviceName: "api"
        )
    }

    private var context: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "dns-command-test",
            resourceUUID:
                "22222222-2222-4222-8222-222222222222",
            resourceGeneration: 1,
            projectResourceUUID:
                "11111111-1111-4111-8111-111111111111",
            projectGeneration: 3,
            providerGeneration: 4,
            fencingToken:
                "33333333-3333-4333-8333-333333333333"
        )
    }

    private func serviceWithDNSLabels() throws
        -> DesiredRuntimeService
    {
        DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:1.1.0",
            labels: try RuntimeProjectDNSContract.workloadLabels(
                projectUUID: context.projectResourceUUID
            )
        )
    }

    private func flagIndices(
        _ flag: String,
        in arguments: [String]
    ) -> [Int] {
        arguments.indices.filter { arguments[$0] == flag }
    }

    private func values(
        for flag: String,
        in arguments: [String]
    ) -> [String] {
        flagIndices(flag, in: arguments).compactMap {
            let valueIndex = arguments.index(after: $0)
            return arguments.indices.contains(valueIndex)
                ? arguments[valueIndex]
                : nil
        }
    }
}
