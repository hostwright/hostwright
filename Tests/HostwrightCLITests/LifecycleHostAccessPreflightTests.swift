import HostwrightNetworking
import HostwrightRuntime
import XCTest
@testable import HostwrightCLI

final class LifecycleHostAccessPreflightTests: XCTestCase {
    func testUnavailableProviderFailsBeforeMutation() throws {
        XCTAssertThrowsError(
            try lifecyclePreflightHostAccessCapabilities(
                services: [service()],
                providerID: .appleContainerization,
                capabilities: .appleContainerizationUnavailable
            )
        ) {
            guard case RuntimeAdapterError
                .mutationUnavailableByPolicy(let message) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertTrue(message.contains("No runtime mutation was attempted."))
        }
    }

    func testQualifiedProviderRequiresOneManagedNetwork() throws {
        XCTAssertNoThrow(
            try lifecyclePreflightHostAccessCapabilities(
                services: [service()],
                providerID: .appleContainerCLI,
                capabilities: .appleContainerCLI
            )
        )

        XCTAssertThrowsError(
            try lifecyclePreflightHostAccessCapabilities(
                services: [service(networks: [])],
                providerID: .appleContainerCLI,
                capabilities: .appleContainerCLI
            )
        )
    }

    private func service(
        networks: [RuntimeDesiredNetworkAttachment]? = nil
    ) -> DesiredRuntimeService {
        let identity = RuntimeServiceIdentity(
            projectName: "demo",
            serviceName: "api"
        )
        return DesiredRuntimeService(
            identity: identity,
            image: "example.invalid/api@sha256:\(String(repeating: "a", count: 64))",
            hostAccess: [
                HostwrightHostAccessEndpoint(
                    hostname: "host-api.internal",
                    protocolName: .tcp,
                    addressClass: .loopback,
                    port: 6_508
                )
            ],
            networks: networks ?? [
                try! RuntimeDesiredNetworkAttachment(
                    network: try! RuntimeNetworkIdentity(
                        logicalName: "app",
                        resourceUUID:
                            HostwrightNetworkIdentity.resourceUUID(
                                projectUUID:
                                    "11111111-1111-4111-8111-111111111111",
                                networkName: "app"
                            ),
                        projectUUID:
                            "11111111-1111-4111-8111-111111111111",
                        runtimeIdentifier:
                            HostwrightNetworkIdentity.runtimeName(
                                projectUUID:
                                    "11111111-1111-4111-8111-111111111111",
                                networkName: "app"
                            )
                    )
                )
            ]
        )
    }
}
