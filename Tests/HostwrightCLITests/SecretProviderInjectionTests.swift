import Foundation
import HostwrightCore
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import HostwrightTestSupport
import XCTest
@testable import HostwrightCLI

final class SecretProviderInjectionTests: XCTestCase {
    private let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let resourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testLifecycleScopePreservesEveryExactWorkloadIdentityField() throws {
        let scope = try lifecycleSecretWorkloadScope(
            projectResourceUUID: projectID.uuidString.lowercased(),
            resourceUUID: resourceID.uuidString.lowercased(),
            generation: 7,
            serviceName: "api"
        )

        XCTAssertEqual(scope.projectID, projectID)
        XCTAssertEqual(scope.resourceID, resourceID)
        XCTAssertEqual(scope.generation, 7)
        XCTAssertEqual(scope.serviceName, "api")
    }

    func testCLIInjectionRequiresExactGrantAcrossEveryScopeDimension() throws {
        let reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.test/api-token"
        )
        let otherReference = try HostwrightSecretReference.parse(
            "keychain://hostwright.test/other-token"
        )
        let exactScope = try workloadScope()
        let registry = try resolver(
            reference: reference,
            workload: exactScope,
            environmentKey: "API_TOKEN"
        )
        let runtimeFactory = RuntimeFactoryCounter()
        let runner = makeRunner(
            resolver: registry,
            runtimeFactory: runtimeFactory
        )

        let resolved = try runner.resolveSecretReferences(
            in: desiredService(reference: reference),
            workload: exactScope
        )
        XCTAssertEqual(resolved.environment.first?.name, "API_TOKEN")
        XCTAssertEqual(resolved.environment.first?.value, FixedSecretProvider.value)
        XCTAssertEqual(resolved.environment.first?.isSensitive, true)
        XCTAssertNil(resolved.environment.first?.secretReference)
        XCTAssertEqual(runtimeFactory.invocationCount, 0)

        let mismatches: [(String, DesiredRuntimeService, HostwrightSecretWorkloadScope)] = [
            (
                "project UUID",
                desiredService(reference: reference),
                try workloadScope(
                    projectID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
                )
            ),
            (
                "resource UUID",
                desiredService(reference: reference),
                try workloadScope(
                    resourceID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
                )
            ),
            (
                "generation",
                desiredService(reference: reference),
                try workloadScope(generation: 8)
            ),
            (
                "service",
                desiredService(reference: reference),
                try workloadScope(serviceName: "worker")
            ),
            (
                "environment key",
                desiredService(
                    reference: reference,
                    environmentKey: "OTHER_TOKEN"
                ),
                exactScope
            ),
            (
                "reference",
                desiredService(reference: otherReference),
                exactScope
            )
        ]

        for (dimension, service, scope) in mismatches {
            XCTAssertThrowsError(
                try runner.resolveSecretReferences(
                    in: service,
                    workload: scope
                ),
                "Expected exact \(dimension) mismatch to fail."
            ) { error in
                guard case SecretStoreError.permissionDenied(let message) = error else {
                    return XCTFail(
                        "Expected permissionDenied for \(dimension), got \(error)."
                    )
                }
                XCTAssertEqual(
                    message,
                    "Secret resolution is not authorized for this exact workload boundary."
                )
                XCTAssertFalse(message.contains(FixedSecretProvider.value))
            }
            XCTAssertEqual(
                runtimeFactory.invocationCount,
                0,
                "A \(dimension) mismatch reached the runtime boundary."
            )
        }
    }

    func testResolvedValueAvoidsArgvPersistedSourceAndRedactedOutput() throws {
        let reference = try HostwrightSecretReference.parse(
            "keychain://hostwright.test/api-token"
        )
        let scope = try workloadScope()
        let sourceService = desiredService(reference: reference)
        let runtimeFactory = RuntimeFactoryCounter()
        let runner = makeRunner(
            resolver: try resolver(
                reference: reference,
                workload: scope,
                environmentKey: "API_TOKEN"
            ),
            runtimeFactory: runtimeFactory
        )
        let resolvedService = try runner.resolveSecretReferences(
            in: sourceService,
            workload: scope
        )

        XCTAssertEqual(sourceService.environment.first?.value, "")
        XCTAssertEqual(sourceService.environment.first?.secretReference, reference)
        XCTAssertFalse(
            sourceService.environment.contains {
                $0.value.contains(FixedSecretProvider.value)
            },
            "The state-facing desired service must retain only the typed reference."
        )

        let command = try AppleContainerCommand.spec(
            kind: .createContainer,
            executable: ResolvedRuntimeExecutable(
                name: "container",
                path: "/usr/local/bin/container"
            ),
            desiredService: resolvedService,
            mutationContext: RuntimeMutationContext(
                providerID: .appleContainerCLI,
                capabilitySHA256: String(repeating: "a", count: 64),
                operationID: "operation-secret-injection",
                resourceUUID: resourceID.uuidString.lowercased(),
                resourceGeneration: 7,
                projectResourceUUID: projectID.uuidString.lowercased(),
                projectGeneration: 1,
                providerGeneration: 1,
                fencingToken: "55555555-5555-4555-8555-555555555555"
            )
        )

        XCTAssertEqual(command.environment["API_TOKEN"], FixedSecretProvider.value)
        XCTAssertFalse(command.arguments.joined(separator: "\u{0}").contains(
            FixedSecretProvider.value
        ))
        XCTAssertTrue(
            command.arguments.indices.contains { index in
                command.arguments[index] == "--env" &&
                    command.arguments.indices.contains(index + 1) &&
                    command.arguments[index + 1] == "API_TOKEN"
            }
        )

        let redactedResult = RuntimeCommandResult(
            spec: command,
            exitStatus: 1,
            standardOutput: "provider output \(FixedSecretProvider.value)",
            standardError: "provider error \(FixedSecretProvider.value)"
        ).redacted()
        let outputSurface = [
            redactedResult.standardOutput,
            redactedResult.standardError,
            redactedResult.spec.arguments.joined(separator: " "),
            redactedResult.spec.environment
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        ].joined(separator: "\n")
        XCTAssertFalse(outputSurface.contains(FixedSecretProvider.value))
        XCTAssertEqual(redactedResult.spec.sensitiveValues, [])
        XCTAssertEqual(runtimeFactory.invocationCount, 0)
    }

    func testInvalidLifecycleIdentityFailsBeforeResolverOrRuntime() throws {
        let resolver = CountingResolver()
        let runtimeFactory = RuntimeFactoryCounter()

        XCTAssertThrowsError(
            try lifecycleSecretWorkloadScope(
                projectResourceUUID: "not-a-uuid",
                resourceUUID: resourceID.uuidString.lowercased(),
                generation: 7,
                serviceName: "api"
            )
        )
        XCTAssertThrowsError(
            try lifecycleSecretWorkloadScope(
                projectResourceUUID: projectID.uuidString.lowercased(),
                resourceUUID: resourceID.uuidString.lowercased(),
                generation: -1,
                serviceName: "api"
            )
        )

        _ = makeRunner(resolver: resolver, runtimeFactory: runtimeFactory)
        XCTAssertEqual(resolver.invocationCount, 0)
        XCTAssertEqual(runtimeFactory.invocationCount, 0)
    }

    private func workloadScope(
        projectID: UUID? = nil,
        resourceID: UUID? = nil,
        generation: Int = 7,
        serviceName: String = "api"
    ) throws -> HostwrightSecretWorkloadScope {
        try HostwrightSecretWorkloadScope(
            projectID: projectID ?? self.projectID,
            resourceID: resourceID ?? self.resourceID,
            generation: generation,
            serviceName: serviceName
        )
    }

    private func resolver(
        reference: HostwrightSecretReference,
        workload: HostwrightSecretWorkloadScope,
        environmentKey: String
    ) throws -> HostwrightSecretProviderRegistry {
        try HostwrightSecretProviderRegistry(
            providers: [try FixedSecretProvider()],
            grants: [
                try HostwrightSecretProviderGrant(
                    providerID: HostwrightSecretProviderKind.keychain.rawValue,
                    reference: reference,
                    workload: workload,
                    environmentKey: environmentKey
                )
            ]
        )
    }

    private func desiredService(
        reference: HostwrightSecretReference,
        environmentKey: String = "API_TOKEN"
    ) -> DesiredRuntimeService {
        DesiredRuntimeService(
            identity: RuntimeServiceIdentity(
                projectName: "demo",
                serviceName: "api"
            ),
            image: "registry.example/api@sha256:\(String(repeating: "b", count: 64))",
            environment: [
                RuntimeEnvironmentValue(
                    name: environmentKey,
                    value: "",
                    isSensitive: true,
                    secretReference: reference
                )
            ]
        )
    }

    private func makeRunner(
        resolver: any HostwrightSecretResolving,
        runtimeFactory: RuntimeFactoryCounter
    ) -> ApplyCommandRunner {
        ApplyCommandRunner(
            manifestPath: "/unused/hostwright.yml",
            stateStoreConfiguration: StateStoreConfiguration(
                explicitDatabasePath: "/unused/state.sqlite"
            ),
            confirmedPlanHash: "",
            environment: CLIEnvironment(
                fileExists: { _ in false },
                readTextFile: { _ in throw CocoaError(.fileReadNoSuchFile) },
                writeTextFile: { _, _ in },
                executablePath: { _ in nil },
                runtimeAdapter: {
                    runtimeFactory.recordInvocation()
                    return ScriptedRuntimeAdapter(scenario: .availableEmpty)
                },
                secretResolver: { resolver },
                swiftVersion: { "Swift 6.3.3" },
                platformSnapshot: {
                    PlatformSnapshot(
                        macOSMajorVersion: 26,
                        architecture: "arm64"
                    )
                },
                operatingSystemDescription: { "macOS 26" }
            )
        )
    }
}

private struct FixedSecretProvider: HostwrightSecretProvider {
    static let value = "scope-only-secret-7f410dd2"

    let descriptor: HostwrightSecretProviderDescriptor

    init() throws {
        descriptor = try HostwrightSecretProviderDescriptor(
            providerID: HostwrightSecretProviderKind.keychain.rawValue,
            kind: .keychain,
            capabilities: [.resolve, .versioned]
        )
    }

    func resolve(
        _ request: HostwrightSecretProviderRequest
    ) throws -> HostwrightSecretResolution {
        HostwrightSecretResolution(
            value: try HostwrightSecretValue(Self.value),
            metadata: try HostwrightSecretResolutionMetadata(
                providerID: descriptor.providerID,
                providerKind: descriptor.kind,
                version: "fixed-v1",
                observedAt: request.resolutionTime
            )
        )
    }
}

private final class RuntimeFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.withLock { count }
    }

    func recordInvocation() {
        lock.withLock { count += 1 }
    }
}

private final class CountingResolver: HostwrightSecretResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var invocationCount: Int {
        lock.withLock { count }
    }

    func resolve(
        reference: HostwrightSecretReference,
        for workload: HostwrightSecretWorkloadScope,
        environmentKey: String,
        at resolutionTime: Date
    ) throws -> HostwrightSecretResolution {
        lock.withLock { count += 1 }
        throw SecretStoreError.backendUnavailable(
            "Counting resolver should not be invoked."
        )
    }
}
