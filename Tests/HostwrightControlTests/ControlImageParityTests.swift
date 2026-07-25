import Foundation
import HostwrightCLI
import HostwrightCore
import HostwrightRuntime
import XCTest
@testable import HostwrightControl

final class ControlImageParityTests: XCTestCase {
    func testEveryImageOperationMapsToTheStrictCLIGrammar() throws {
        let state = "/private/tmp/hostwright-state.sqlite"
        let configuration = LocalControlConfiguration(
            manifestPath: "/unused-for-image-operations",
            stateDatabasePath: state
        )
        let requests = [
            LocalControlRequest(
                requestID: "image-inspect",
                operation: .image,
                imageOperation: "inspect",
                imageReferences: ["registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "image-pull",
                operation: .image,
                runtimeProvider: "apple-cli",
                imageOperation: "pull",
                imageReferences: ["registry.example/app:v1"],
                imagePlatform: "linux/arm64",
                imageOffline: true,
                imageProgress: "none"
            ),
            LocalControlRequest(
                requestID: "image-push",
                operation: .image,
                imageOperation: "push",
                imageReferences: ["registry.example/app:v1"],
                imageProgress: "plain"
            ),
            LocalControlRequest(
                requestID: "image-tag",
                operation: .image,
                imageOperation: "tag",
                imageReferences: ["registry.example/app:v1"],
                imageTargetReference: "registry.example/app:stable"
            ),
            LocalControlRequest(
                requestID: "image-load",
                operation: .image,
                imageOperation: "load",
                imageReferences: [
                    "registry.example/app:v1",
                    "registry.example/sidecar:v1"
                ],
                imageArchivePath: "/private/tmp/images.oci"
            ),
            LocalControlRequest(
                requestID: "image-save",
                operation: .image,
                imageOperation: "save",
                imageReferences: ["registry.example/app:v1"],
                imageArchivePath: "/private/tmp/images.oci",
                imagePlatform: "linux/arm64"
            ),
            LocalControlRequest(
                requestID: "image-build",
                operation: .image,
                imageOperation: "build",
                imageTargetReference: "registry.example/app:v2",
                imageContextPath: "/private/tmp/context",
                imageFilePath: "/private/tmp/context/Containerfile",
                imagePlatform: "linux/arm64",
                imageOffline: true,
                imageNoCache: true
            ),
            LocalControlRequest(
                requestID: "image-delete",
                operation: .image,
                imageOperation: "delete",
                imageReferences: ["registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "image-prune",
                operation: .image,
                dryRun: true,
                imageOperation: "prune",
                imageMaximumBytes: 1_024,
                imageTargetBytes: 512,
                imageRetentionSeconds: 3_600,
                imageMaximumDeletions: 4
            ),
            LocalControlRequest(
                requestID: "image-cache-status",
                operation: .image,
                imageOperation: "cache-status",
                imageMaximumBytes: 1_024
            ),
            LocalControlRequest(
                requestID: "image-cache-pin",
                operation: .image,
                imageOperation: "pin",
                imageReferences: ["registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "image-cache-unpin",
                operation: .image,
                imageOperation: "unpin",
                imageReferences: ["registry.example/app:v1"]
            )
        ]

        for request in requests {
            let encoded = try JSONEncoder().encode(request)
            XCTAssertEqual(
                try LocalControlRequestParser.parse(encoded),
                request
            )
            let arguments = try LocalControlAPI.commandArguments(
                for: request,
                configuration: configuration
            )
            guard case .image = try CLICommand.parse(arguments: arguments) else {
                return XCTFail(
                    "Control request did not map to image CLI: \(request.requestID)."
                )
            }
            XCTAssertTrue(arguments.contains("--state-db"))
            XCTAssertTrue(arguments.contains("--json"))
        }
    }

    func testImageControlRejectsUnsafeOrCrossOperationFields() {
        let invalid = [
            LocalControlRequest(
                requestID: "bad-reference",
                operation: .image,
                imageOperation: "pull",
                imageReferences: ["user:secret@registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "bad-load",
                operation: .image,
                imageOperation: "load",
                imageArchivePath: "/private/tmp/images.oci"
            ),
            LocalControlRequest(
                requestID: "bad-prune",
                operation: .image,
                imageOperation: "prune",
                imageReferences: ["registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "bad-empty-prune-references",
                operation: .image,
                imageOperation: "prune",
                imageReferences: []
            ),
            LocalControlRequest(
                requestID: "bad-explicit-inspect-offline",
                operation: .image,
                imageOperation: "inspect",
                imageReferences: ["registry.example/app:v1"],
                imageOffline: false
            ),
            LocalControlRequest(
                requestID: "bad-explicit-pull-no-cache",
                operation: .image,
                imageOperation: "pull",
                imageReferences: ["registry.example/app:v1"],
                imageNoCache: false
            ),
            LocalControlRequest(
                requestID: "bad-build-path",
                operation: .image,
                imageOperation: "build",
                imageTargetReference: "registry.example/app:v2",
                imageContextPath: "/private/tmp/context",
                imageFilePath: "/private/tmp/other/Containerfile"
            ),
            LocalControlRequest(
                requestID: "bad-lifecycle-field",
                operation: .image,
                dryRun: true,
                imageOperation: "inspect",
                imageReferences: ["registry.example/app:v1"]
            ),
            LocalControlRequest(
                requestID: "bad-prune-pressure-pair",
                operation: .image,
                imageOperation: "prune",
                imageMaximumBytes: 1_024
            ),
            LocalControlRequest(
                requestID: "bad-prune-double-confirmation",
                operation: .image,
                dryRun: true,
                confirmPlan: String(repeating: "a", count: 64),
                imageOperation: "prune"
            ),
            LocalControlRequest(
                requestID: "bad-cache-status-target",
                operation: .image,
                imageOperation: "cache-status",
                imageTargetBytes: 512
            ),
            LocalControlRequest(
                requestID: "bad-pin-policy",
                operation: .image,
                imageOperation: "pin",
                imageReferences: ["registry.example/app:v1"],
                imageRetentionSeconds: 60
            )
        ]

        for request in invalid {
            XCTAssertThrowsError(
                try LocalControlRequestParser.validate(request),
                "Expected rejection for \(request.requestID)."
            )
        }
    }

    func testOneShotControlExecutesImageInspectThroughSharedProviderContract() throws {
        let provider = ImageControlInspectProvider()
        let environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            runtimeAdapter: { provider },
            runtimeAdapterForProvider: { providerID in
                guard providerID == .appleContainerCLI else {
                    throw RuntimeProviderSelectionError.providerUnavailable(
                        providerID
                    )
                }
                return provider
            },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "test" }
        )
        let api = LocalControlAPI(
            configuration: LocalControlConfiguration(
                manifestPath: "/not-required-for-image-inspect"
            ),
            environment: environment
        )
        let request = LocalControlRequest(
            requestID: "image-inspect-shared",
            operation: .image,
            runtimeProvider: "apple-cli",
            imageOperation: "inspect",
            imageReferences: ["registry.example/app:v1"]
        )

        let result = api.run(
            requestData: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardError.isEmpty)
        let response = try JSONDecoder().decode(
            LocalControlResponse.self,
            from: result.standardOutput
        )
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.operation, .image)
        guard case .object(let object) = response.result else {
            return XCTFail("Expected one structured image result object.")
        }
        XCTAssertEqual(object["operation"], .string("inspect"))
        XCTAssertEqual(
            object["provider"],
            .string(RuntimeProviderID.appleContainerCLI.rawValue)
        )
    }

    func testOneShotControlCreatesFreshImageStateThroughSharedCLIPath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-control-image-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory.appendingPathComponent("state.sqlite").path
        let provider = ImageControlPullProvider()
        let environment = CLIEnvironment(
            fileExists: { _ in false },
            readTextFile: { _ in "" },
            writeTextFile: { _, _ in },
            executablePath: { _ in nil },
            runtimeAdapter: { provider },
            runtimeAdapterForProvider: { providerID in
                guard providerID == .appleContainerCLI else {
                    throw RuntimeProviderSelectionError.providerUnavailable(
                        providerID
                    )
                }
                return provider
            },
            swiftVersion: { nil },
            platformSnapshot: {
                PlatformSnapshot(macOSMajorVersion: 26, architecture: "arm64")
            },
            operatingSystemDescription: { "test" }
        )
        let api = LocalControlAPI(
            configuration: LocalControlConfiguration(
                manifestPath: "/not-required-for-image-pull",
                stateDatabasePath: statePath
            ),
            environment: environment
        )
        let request = LocalControlRequest(
            requestID: "image-pull-fresh-state",
            operation: .image,
            runtimeProvider: "apple-cli",
            imageOperation: "pull",
            imageReferences: ["registry.example/app:fresh"],
            imageProgress: "none"
        )

        let result = api.run(
            requestData: try JSONEncoder().encode(request)
        )

        XCTAssertEqual(
            result.exitCode,
            0,
            String(decoding: result.standardOutput, as: UTF8.self)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: statePath))
        let response = try JSONDecoder().decode(
            LocalControlResponse.self,
            from: result.standardOutput
        )
        XCTAssertTrue(response.success)
        let operations = await provider.operations()
        XCTAssertEqual(operations, [.pull])
    }
}

private actor ImageControlPullProvider: RuntimeImageLifecycleProviding {
    private static let capabilitySHA256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let descriptorDigest =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let variantDigest =
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    private var references: Set<String> = []
    private var operationLog: [RuntimeImageLifecycleOperation] = []

    func operations() -> [RuntimeImageLifecycleOperation] {
        operationLog
    }

    func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: Self.capabilitySHA256,
            operations: RuntimeImageLifecycleOperation.allCases.map {
                RuntimeImageOperationCapability(
                    operation: $0,
                    state: $0 == .pull ? .available : .unavailable,
                    reason: $0 == .pull
                        ? .implemented
                        : .providerUnsupported
                )
            }
        )
    }

    func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        let planSHA256 = try request.planSHA256()
        guard request.operation == .pull,
              confirmation?.confirmed == true,
              confirmation?.planHash == planSHA256 else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("test")
        }
        operationLog.append(.pull)
        references.formUnion(request.sourceReferences)
        return try RuntimeImageOperationResult(
            operation: .pull,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: planSHA256,
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0-test",
            disposition: .succeeded,
            images: request.sourceReferences.map(Self.record)
        )
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "ImageControlPullProvider",
            adapterVersion: "test",
            runtimeName: "test",
            runtimeVersion: "1.1.0-test",
            supportsMutation: true,
            capabilities: [.readOnlyObservation, .lifecycleMutation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation, .lifecycleMutation]
    }

    func inventory() async throws -> RuntimeInventory {
        try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "linux",
                architecture: "arm64",
                runtimeVersion: "1.1.0-test",
                services: []
            ),
            containers: [],
            images: references.sorted().map {
                RuntimeInventoryImage(
                    runtimeID: "image-\($0)",
                    descriptorDigest: Self.descriptorDigest,
                    references: [$0],
                    variants: [
                        RuntimeInventoryImageVariant(
                            digest: Self.variantDigest,
                            architecture: "arm64",
                            operatingSystem: "linux"
                        )
                    ],
                    labels: []
                )
            },
            networks: [],
            volumes: []
        )
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: desiredState.projectName, services: [])
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String {
        "1.1.0-test"
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("test")
    }

    private static func record(
        _ reference: String
    ) throws -> RuntimeImageRecord {
        try RuntimeImageRecord(
            digest: descriptorDigest,
            references: [reference],
            mediaType: "application/vnd.oci.image.index.v1+json",
            sizeBytes: 1,
            variants: [
                try RuntimeImageVariantRecord(
                    digest: variantDigest,
                    operatingSystem: "linux",
                    architecture: "arm64",
                    sizeBytes: 1
                )
            ]
        )
    }
}

private struct ImageControlInspectProvider: RuntimeImageLifecycleProviding {
    private static let capabilitySHA256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let descriptorDigest =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let variantDigest =
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: Self.capabilitySHA256,
            operations: RuntimeImageLifecycleOperation.allCases.map {
                RuntimeImageOperationCapability(
                    operation: $0,
                    state: $0 == .inspect ? .available : .unavailable,
                    reason: $0 == .inspect
                        ? .implemented
                        : .providerUnsupported
                )
            }
        )
    }

    func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        guard request.operation == .inspect,
              confirmation == nil else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("test")
        }
        let image = try RuntimeImageRecord(
            digest: Self.descriptorDigest,
            references: request.sourceReferences,
            mediaType: "application/vnd.oci.image.index.v1+json",
            sizeBytes: 1,
            variants: [
                try RuntimeImageVariantRecord(
                    digest: Self.variantDigest,
                    operatingSystem: "linux",
                    architecture: "arm64",
                    sizeBytes: 1
                )
            ]
        )
        return try RuntimeImageOperationResult(
            operation: .inspect,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: .appleContainerCLI,
            providerVersion: "1.1.0-test",
            disposition: .unchanged,
            images: [image]
        )
    }

    func metadata() async -> RuntimeAdapterMetadata {
        RuntimeAdapterMetadata(
            providerID: .appleContainerCLI,
            adapterName: "ImageControlInspectProvider",
            adapterVersion: "test",
            runtimeName: "test",
            runtimeVersion: "1.1.0-test",
            supportsMutation: false,
            capabilities: [.readOnlyObservation]
        )
    }

    func capabilities() async throws -> [RuntimeCapability] {
        [.readOnlyObservation]
    }

    func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        ObservedRuntimeState(projectName: desiredState.projectName, services: [])
    }

    func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        RuntimePlan(actions: [])
    }

    func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        throw RuntimeAdapterError.capabilityUnavailable(.logStreaming)
    }

    func runtimeVersion() async throws -> String {
        "1.1.0-test"
    }

    func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        throw RuntimeAdapterError.mutationUnavailableByPolicy("test")
    }
}
