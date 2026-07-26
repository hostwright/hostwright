import XCTest
@testable import HostwrightRuntime

final class RuntimeCommandPolicyDNSTests: XCTestCase {
    func testPolicyAcceptsExactProjectDNSBinding() throws {
        let spec = try validDNSSpec()

        XCTAssertNoThrow(
            try RuntimeCommandPolicy
                .validateCreateMissingServiceMutation(spec)
        )
    }

    func testPolicyRejectsDNSOptionsWithoutProjectDNSLabels() throws {
        let service = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:1.1.0"
        )
        let spec = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: service,
            mutationContext: context,
            dnsServers: ["10.44.0.53"],
            dnsSearchDomains: [zone]
        )

        XCTAssertThrowsError(
            try RuntimeCommandPolicy
                .validateCreateMissingServiceMutation(spec)
        )
    }

    func testPolicyRejectsProjectDNSLabelsWithoutResolution() throws {
        let spec = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: try serviceWithDNSLabels(),
            mutationContext: context
        )

        XCTAssertThrowsError(
            try RuntimeCommandPolicy
                .validateCreateMissingServiceMutation(spec)
        )
    }

    func testPolicyRejectsDuplicateInvalidAndUnsortedServers() throws {
        let valid = try validDNSSpec()
        for servers in [
            ["10.44.0.53", "10.44.0.53"],
            ["fd00:44::53", "10.44.0.53"],
            ["not-an-address"]
        ] {
            let tampered = replacingOptions(
                in: valid,
                servers: servers,
                searchDomains: [zone]
            )
            XCTAssertThrowsError(
                try RuntimeCommandPolicy
                    .validateCreateMissingServiceMutation(tampered),
                servers.joined(separator: ",")
            )
        }
    }

    func testPolicyRejectsWrongOrDuplicateSearchDomains() throws {
        let valid = try validDNSSpec()
        for domains in [
            ["other.hostwright.internal"],
            [zone, zone],
            []
        ] {
            let tampered = replacingOptions(
                in: valid,
                servers: ["10.44.0.53"],
                searchDomains: domains
            )
            XCTAssertThrowsError(
                try RuntimeCommandPolicy
                    .validateCreateMissingServiceMutation(tampered),
                domains.joined(separator: ",")
            )
        }
    }

    func testPolicyRejectsInfrastructureCreateWithDNSOptions() throws {
        let service = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:1.1.0",
            labels:
                try RuntimeProjectDNSContract.infrastructureLabels(
                    projectUUID: context.projectResourceUUID
                )
        )
        let spec = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: service,
            mutationContext: context,
            dnsServers: ["10.44.0.53"],
            dnsSearchDomains: [zone]
        )

        XCTAssertThrowsError(
            try RuntimeCommandPolicy
                .validateCreateMissingServiceMutation(spec)
        )
    }

    func testPolicyRejectsIncompleteProjectDNSLabels() throws {
        let service = DesiredRuntimeService(
            identity: identity,
            image: "ghcr.io/example/api:1.1.0",
            labels: [
                RuntimeProjectDNSContract.resourceUUIDLabel:
                    "99999999-9999-4999-8999-999999999999"
            ]
        )
        let spec = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: service,
            mutationContext: context,
            dnsServers: ["10.44.0.53"],
            dnsSearchDomains: [zone]
        )

        XCTAssertThrowsError(
            try RuntimeCommandPolicy
                .validateCreateMissingServiceMutation(spec)
        )
    }

    private var zone: String {
        "\(context.projectResourceUUID).hostwright.internal"
    }

    private var identity: RuntimeServiceIdentity {
        RuntimeServiceIdentity(
            projectName: "proof",
            serviceName: "api"
        )
    }

    private var executable: ResolvedRuntimeExecutable {
        ResolvedRuntimeExecutable(
            name: "container",
            path: "/usr/bin/container-fixture"
        )
    }

    private var context: RuntimeMutationContext {
        RuntimeMutationContext(
            providerID: .appleContainerCLI,
            capabilitySHA256: String(repeating: "a", count: 64),
            operationID: "dns-policy-test",
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

    private func validDNSSpec() throws -> RuntimeCommandSpec {
        try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: executable,
            desiredService: serviceWithDNSLabels(),
            mutationContext: context,
            dnsServers: ["10.44.0.53", "fd00:44::53"],
            dnsSearchDomains: [zone]
        )
    }

    private func replacingOptions(
        in spec: RuntimeCommandSpec,
        servers: [String],
        searchDomains: [String]
    ) -> RuntimeCommandSpec {
        let imageIndex = spec.arguments.firstIndex(
            of: "ghcr.io/example/api:1.1.0"
        )!
        var arguments: [String] = []
        var index = 0
        while index < imageIndex {
            if spec.arguments[index] == "--dns" ||
                spec.arguments[index] == "--dns-search" {
                index += 2
            } else {
                arguments.append(spec.arguments[index])
                index += 1
            }
        }
        for server in servers {
            arguments += ["--dns", server]
        }
        for domain in searchDomains {
            arguments += ["--dns-search", domain]
        }
        arguments += spec.arguments[imageIndex...]

        return RuntimeCommandSpec(
            executablePath: spec.executablePath,
            arguments: arguments,
            environment: spec.environment,
            sensitiveValues: spec.sensitiveValues,
            workingDirectory: spec.workingDirectory,
            timeout: spec.timeout,
            classification: spec.classification,
            executableResolution: spec.executableResolution,
            mutationKind: spec.mutationKind,
            exitStatusPolicy: spec.exitStatusPolicy,
            purpose: spec.purpose
        )
    }
}
