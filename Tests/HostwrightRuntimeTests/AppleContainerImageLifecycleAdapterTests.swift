import Foundation
import HostwrightTestSupport
import XCTest
@testable import HostwrightRuntime

final class AppleContainerImageLifecycleAdapterTests: XCTestCase {
    func testTagUsesExactMutationAndVerifiesDigestFromStructuredObservation() async throws {
        let source = "registry.example.test/team/app:source"
        let target = "registry.example.test/team/app:target"
        let runner = ImageLifecycleProcessRunner(
            imageLists: [
                Self.imageList(references: [source]),
                Self.imageList(references: [source, target])
            ],
            mutationOutput: "untrusted mutation output that is never parsed"
        )
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .tag,
            capability: capability,
            sourceReferences: [source],
            targetReference: target
        )
        let events = ImageProgressEventRecorder()

        let result = try await adapter.performImageOperation(
            request,
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "test",
                planHash: request.planSHA256()
            ),
            progress: { event in
                await events.append(event)
            }
        )

        XCTAssertEqual(result.images.map(\.digest), [Self.configurationDigest])
        XCTAssertEqual(result.images.first?.references, [source, target])
        XCTAssertEqual(result.disposition, .succeeded)
        let mutations = await runner.mutationSpecs()
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(
            mutations.first?.arguments,
            ["image", "tag", source, target]
        )
        XCTAssertEqual(mutations.first?.environment, [:])
        XCTAssertEqual(mutations.first?.sensitiveValues, [])
        let progress = await events.values()
        XCTAssertEqual(
            progress.map(\.stage),
            [.resolving, .writing, .verifying, .complete]
        )
        XCTAssertEqual(progress.map(\.sequence), [0, 1, 2, 3])
    }

    func testDeleteUsesOnlyExactReferencesAndRequiresPostOperationAbsence() async throws {
        let reference = "registry.example.test/team/app:old"
        let runner = ImageLifecycleProcessRunner(
            imageLists: [
                Self.imageList(references: [reference]),
                "[]"
            ]
        )
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .delete,
            capability: capability,
            sourceReferences: [reference]
        )

        let result = try await adapter.performImageOperation(
            request,
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "test",
                planHash: request.planSHA256()
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.images, [])
        XCTAssertEqual(result.deletedDigests, [Self.configurationDigest])
        let mutations = await runner.mutationSpecs()
        XCTAssertEqual(mutations.map(\.arguments), [["image", "delete", reference]])
        XCTAssertFalse(mutations[0].arguments.contains("--all"))
        XCTAssertFalse(mutations[0].arguments.contains("--force"))
        XCTAssertFalse(mutations[0].arguments.contains("prune"))
    }

    func testDeleteDigestDriftIsRejectedBeforeNativeMutation() async throws {
        let reference = "registry.example.test/team/app:replaced"
        let runner = ImageLifecycleProcessRunner(
            imageLists: [Self.imageList(references: [reference])]
        )
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try RuntimeImageLifecycleRequest(
            operation: .delete,
            operationID: "11111111-1111-4111-8111-111111111111",
            idempotencyKey:
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            capabilitySHA256: capability.capabilitySHA256,
            sourceReferences: [reference],
            expectedSourceDigests: [
                reference:
                    "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            ]
        )

        do {
            _ = try await adapter.performImageOperation(
                request,
                confirmation: RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "test",
                    planHash: request.planSHA256()
                ),
                progress: { _ in }
            )
            XCTFail("Expected digest drift refusal.")
        } catch let error as RuntimeImageLifecycleContractError {
            XCTAssertEqual(error, .invalidResult)
        }

        let mutations = await runner.mutationSpecs()
        XCTAssertEqual(mutations, [])
    }

    func testEmptyPruneIsAConfirmedNoOpWithoutNativeMutation() async throws {
        let runner = ImageLifecycleProcessRunner(imageLists: [])
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .prune,
            capability: capability,
            sourceReferences: []
        )

        let result = try await adapter.performImageOperation(
            request,
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "test",
                planHash: request.planSHA256()
            ),
            progress: { _ in }
        )

        XCTAssertEqual(result.disposition, .unchanged)
        XCTAssertEqual(result.images, [])
        XCTAssertEqual(result.deletedDigests, [])
        let mutations = await runner.mutationSpecs()
        let observations = await runner.imageListCallCount()
        XCTAssertEqual(mutations, [])
        XCTAssertEqual(observations, 0)
    }

    func testLoadRejectsAndCompensatesUndeclaredInventoryDelta() async throws {
        let expected = "registry.example.test/team/app:expected"
        let extra = "registry.example.test/team/app:undeclared"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-image-load-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("input.oci").path
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: archive,
                contents: Data("archive".utf8)
            )
        )
        let runner = ImageLifecycleProcessRunner(
            imageLists: [
                "[]",
                Self.imageList(references: [expected, extra]),
                "[]"
            ]
        )
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .load,
            capability: capability,
            sourceReferences: [expected],
            archivePath: archive
        )

        do {
            _ = try await adapter.performImageOperation(
                request,
                confirmation: RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "test",
                    planHash: request.planSHA256()
                ),
                progress: { _ in }
            )
            XCTFail("Expected undeclared load delta rejection.")
        } catch let error as RuntimeImageLifecycleContractError {
            XCTAssertEqual(error, .invalidResult)
        }

        let mutations = await runner.mutationSpecs()
        XCTAssertEqual(
            mutations.map(\.arguments),
            [
                ["image", "load", "--input", archive],
                ["image", "delete", expected, extra]
            ]
        )
    }

    func testOfflineNetworkOperationIsRejectedBeforeMutationOrObservation() async throws {
        let reference = "registry.example.test/team/app:offline"
        let runner = ImageLifecycleProcessRunner(imageLists: [])
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .pull,
            capability: capability,
            sourceReferences: [reference],
            offline: true
        )

        do {
            _ = try await adapter.performImageOperation(
                request,
                confirmation: RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "test",
                    planHash: request.planSHA256()
                ),
                progress: { _ in }
            )
            XCTFail("Expected offline pull to fail before effects.")
        } catch let error as RuntimeImageLifecycleContractError {
            XCTAssertEqual(
                error,
                .unavailable(operation: .pull, reason: .policyBlocked)
            )
        }

        let mutations = await runner.mutationSpecs()
        let observations = await runner.imageListCallCount()
        XCTAssertEqual(mutations, [])
        XCTAssertEqual(observations, 0)
    }

    func testMutationFailureNeverReturnsProviderOutput() async throws {
        let reference = "registry.example.test/team/app:source"
        let leakedValue = "provider-returned-sensitive-value"
        let runner = ImageLifecycleProcessRunner(
            imageLists: [Self.imageList(references: [reference])],
            mutationError: .commandFailed(
                exitStatus: 1,
                message: leakedValue,
                standardError: leakedValue
            )
        )
        let adapter = Self.adapter(runner: runner)
        let capability = try await adapter.imageOperationCapabilities()
        let request = try Self.request(
            operation: .push,
            capability: capability,
            sourceReferences: [reference],
            targetReference: reference
        )

        do {
            _ = try await adapter.performImageOperation(
                request,
                confirmation: RuntimeMutationConfirmation(
                    confirmed: true,
                    reason: "test",
                    planHash: request.planSHA256()
                ),
                progress: { _ in }
            )
            XCTFail("Expected mutation failure.")
        } catch let error as RuntimeAdapterError {
            XCTAssertFalse(String(describing: error).contains(leakedValue))
            guard case .commandFailed(_, _, let standardError) = error else {
                return XCTFail("Expected sanitized command failure, got \(error).")
            }
            XCTAssertEqual(standardError, "")
        }
    }

    func testMutationPolicyRejectsBroadNativeAndCredentialArguments() throws {
        let valid = RuntimeCommandSpec(
            executablePath: "/usr/local/bin/container",
            arguments: [
                "image", "pull", "--scheme", "https", "--progress", "none",
                "registry.example.test/team/app:v1"
            ],
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .imageLifecycle,
            purpose: "test"
        )
        XCTAssertNoThrow(
            try RuntimeCommandPolicy.validateImageLifecycleMutation(valid)
        )

        for arguments in [
            ["image", "delete", "--all"],
            ["image", "delete", "--force", "registry.example.test/app:v1"],
            ["image", "prune"],
            [
                "image", "pull", "--username", "person",
                "registry.example.test/app:v1"
            ],
            [
                "image", "pull", "--password", "secret",
                "registry.example.test/app:v1"
            ]
        ] {
            let rejected = RuntimeCommandSpec(
                executablePath: "/usr/local/bin/container",
                arguments: arguments,
                classification: .mutating,
                executableResolution: .resolvedByRuntimeExecutableResolver,
                mutationKind: .imageLifecycle,
                purpose: "test"
            )
            XCTAssertThrowsError(
                try RuntimeCommandPolicy.validateImageLifecycleMutation(rejected),
                "Expected rejection for \(arguments)."
            )
        }
    }

    func testEveryRemainingOperationUsesQualifiedShapeAndStructuredObservation() async throws {
        let reference = "registry.example.test/team/app:v1"
        let target = "registry.example.test/team/app:v2"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-image-adapter-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let loadArchive = directory.appendingPathComponent("load.oci").path
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: loadArchive,
                contents: Data("archive".utf8)
            )
        )
        let saveArchive = directory.appendingPathComponent("save.oci").path
        let dockerfile = directory.appendingPathComponent("Containerfile").path
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: dockerfile,
                contents: Data("FROM scratch\n".utf8)
            )
        )

        let cases: [(
            RuntimeImageLifecycleOperation,
            [String],
            [String],
            [String],
            String?,
            String?,
            String?
        )] = [
            (
                .inspect,
                [Self.imageList(references: [reference])],
                [],
                [reference],
                nil,
                nil,
                nil
            ),
            (
                .pull,
                ["[]", Self.imageList(references: [reference])],
                [
                    "image", "pull", "--scheme", "https", "--progress",
                    "none", "--platform", "linux/arm64", reference
                ],
                [reference],
                nil,
                nil,
                nil
            ),
            (
                .push,
                [
                    Self.imageList(references: [reference]),
                    Self.imageList(references: [reference])
                ],
                [
                    "image", "push", "--scheme", "https", "--progress",
                    "none", "--platform", "linux/arm64", reference
                ],
                [reference],
                reference,
                nil,
                nil
            ),
            (
                .load,
                ["[]", Self.imageList(references: [reference])],
                ["image", "load", "--input", loadArchive],
                [reference],
                nil,
                nil,
                loadArchive
            ),
            (
                .save,
                [
                    Self.imageList(references: [reference]),
                    Self.imageList(references: [reference])
                ],
                [
                    "image", "save", "--output", saveArchive, "--platform",
                    "linux/arm64", reference
                ],
                [reference],
                nil,
                nil,
                saveArchive
            ),
            (
                .build,
                ["[]", Self.imageList(references: [target])],
                [
                    "build", "--tag", target, "--quiet", "--file",
                    dockerfile, "--platform", "linux/arm64", "--no-cache",
                    directory.path
                ],
                [],
                target,
                directory.path,
                nil
            ),
            (
                .prune,
                [Self.imageList(references: [reference]), "[]"],
                ["image", "delete", reference],
                [reference],
                nil,
                nil,
                nil
            )
        ]

        for (
            operation,
            imageLists,
            expectedArguments,
            sourceReferences,
            targetReference,
            contextPath,
            archivePath
        ) in cases {
            if operation == .save {
                try? FileManager.default.removeItem(atPath: saveArchive)
            }
            let runner = ImageLifecycleProcessRunner(
                imageLists: imageLists,
                createSaveArchive: operation == .save
            )
            let adapter = Self.adapter(runner: runner)
            let capability = try await adapter.imageOperationCapabilities()
            let usesPlatform = operation == .pull || operation == .push ||
                operation == .save || operation == .build
            let digestBound = operation == .push ||
                operation == .tag ||
                operation == .save ||
                operation == .delete ||
                operation == .prune
            let request = try RuntimeImageLifecycleRequest(
                operation: operation,
                operationID: "11111111-1111-4111-8111-111111111111",
                idempotencyKey:
                    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
                capabilitySHA256: capability.capabilitySHA256,
                sourceReferences: sourceReferences,
                expectedSourceDigests: digestBound
                    ? Dictionary(
                        sourceReferences.map {
                            ($0, Self.configurationDigest)
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                    : [:],
                targetReference: targetReference,
                contextPath: contextPath,
                dockerfilePath: operation == .build ? dockerfile : nil,
                archivePath: archivePath,
                platformOS: usesPlatform ? "linux" : nil,
                platformArchitecture: usesPlatform ? "arm64" : nil,
                noCache: operation == .build
            )
            let result = try await adapter.performImageOperation(
                request,
                confirmation: operation == .inspect
                    ? nil
                    : RuntimeMutationConfirmation(
                        confirmed: true,
                        reason: "test",
                        planHash: request.planSHA256()
                    ),
                progress: { _ in }
            )

            XCTAssertEqual(result.operation, operation)
            let mutations = await runner.mutationSpecs()
            if operation == .inspect {
                XCTAssertEqual(mutations, [])
            } else {
                XCTAssertEqual(
                    mutations.map(\.arguments),
                    [expectedArguments],
                    "Unexpected native shape for \(operation)."
                )
            }
        }
    }

    private static let configurationDigest =
        "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private static let variantDigest =
        "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private static let layerDigest =
        "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

    private static func adapter(
        runner: ImageLifecycleProcessRunner
    ) -> AppleContainerImageLifecycleAdapter {
        AppleContainerImageLifecycleAdapter(
            executableResolver: DictionaryRuntimeExecutableResolver(
                executables: [
                    AppleContainerCommand.executableName:
                        "/usr/local/bin/container"
                ]
            ),
            processRunner: runner
        )
    }

    private static func request(
        operation: RuntimeImageLifecycleOperation,
        capability: RuntimeImageOperationCapabilityContract,
        sourceReferences: [String],
        targetReference: String? = nil,
        archivePath: String? = nil,
        offline: Bool = false
    ) throws -> RuntimeImageLifecycleRequest {
        let digestBound = operation == .push ||
            operation == .tag ||
            operation == .save ||
            operation == .delete ||
            operation == .prune
        return try RuntimeImageLifecycleRequest(
            operation: operation,
            operationID: "11111111-1111-4111-8111-111111111111",
            idempotencyKey:
                "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            capabilitySHA256: capability.capabilitySHA256,
            sourceReferences: sourceReferences,
            expectedSourceDigests: digestBound
                ? Dictionary(
                    sourceReferences.map {
                        ($0, Self.configurationDigest)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                : [:],
            targetReference: targetReference,
            archivePath: archivePath,
            offline: offline
        )
    }

    private static func imageList(references: [String]) -> String {
        let objects = references.map { reference in
            """
            {
              "configuration": {
                "creationDate": "2026-07-24T12:00:00Z",
                "descriptor": {
                  "digest": "\(configurationDigest)",
                  "mediaType": "application/vnd.oci.image.config.v1+json",
                  "size": 512
                },
                "name": "\(reference)"
              },
              "variants": [{
                "config": {
                  "rootfs": {
                    "diff_ids": ["\(layerDigest)"]
                  }
                },
                "digest": "\(variantDigest)",
                "platform": {
                  "architecture": "arm64",
                  "os": "linux"
                },
                "size": 1024
              }]
            }
            """
        }
        return "[\(objects.joined(separator: ","))]"
    }
}

private actor ImageProgressEventRecorder {
    private var events: [RuntimeImageProgressEvent] = []

    func append(_ event: RuntimeImageProgressEvent) {
        events.append(event)
    }

    func values() -> [RuntimeImageProgressEvent] {
        events
    }
}

private actor ImageLifecycleProcessRunner: RuntimeProcessRunning {
    private var imageLists: [String]
    private let mutationOutput: String
    private let mutationError: RuntimeAdapterError?
    private let createSaveArchive: Bool
    private var specs: [RuntimeCommandSpec] = []

    init(
        imageLists: [String],
        mutationOutput: String = "",
        mutationError: RuntimeAdapterError? = nil,
        createSaveArchive: Bool = false
    ) {
        self.imageLists = imageLists
        self.mutationOutput = mutationOutput
        self.mutationError = mutationError
        self.createSaveArchive = createSaveArchive
    }

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        specs.append(spec)
        let output: String
        switch spec.arguments {
        case ["--version"]:
            output =
                "container CLI version 1.1.0 (build: release, commit: 5973b9c)\n"
        case ["image", "list", "--format", "json"]:
            guard !imageLists.isEmpty else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Unexpected image observation."
                )
            }
            output = imageLists.removeFirst()
        default:
            guard spec.classification == .mutating else {
                throw RuntimeAdapterError.commandRejected(
                    classification: spec.classification,
                    message: "Unexpected read-only command."
                )
            }
            if let mutationError {
                throw mutationError
            }
            if createSaveArchive,
               spec.arguments.count >= 4,
               Array(spec.arguments.prefix(3)) ==
                ["image", "save", "--output"] {
                guard FileManager.default.createFile(
                    atPath: spec.arguments[3],
                    contents: Data("saved".utf8)
                ) else {
                    throw RuntimeAdapterError.commandFailed(
                        exitStatus: 1,
                        message: "Could not create test archive.",
                        standardError: ""
                    )
                }
            }
            output = mutationOutput
        }
        return RuntimeCommandResult(
            spec: spec,
            exitStatus: 0,
            standardOutput: output,
            standardError: ""
        )
    }

    func mutationSpecs() -> [RuntimeCommandSpec] {
        specs.filter { $0.classification == .mutating }
    }

    func imageListCallCount() -> Int {
        specs.filter {
            $0.arguments == ["image", "list", "--format", "json"]
        }.count
    }
}
