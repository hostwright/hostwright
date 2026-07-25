import CryptoKit
import Darwin
import Foundation

public struct AppleContainerImageLifecycleAdapter: RuntimeImageLifecycleProviding {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy
    private let base: AppleContainerApplyAdapter

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
        self.base = AppleContainerApplyAdapter(
            executableResolver: executableResolver,
            processRunner: processRunner,
            redactionPolicy: redactionPolicy
        )
    }

    public func metadata() async -> RuntimeAdapterMetadata {
        await base.metadata()
    }

    public func capabilities() async throws -> [RuntimeCapability] {
        try await base.capabilities()
    }

    public func capabilitySnapshot() async throws -> RuntimeCapabilitySnapshot {
        try await base.capabilitySnapshot()
    }

    public func inventory() async throws -> RuntimeInventory {
        try await base.inventory()
    }

    public func observe(
        desiredState: DesiredRuntimeState
    ) async throws -> ObservedRuntimeState {
        try await base.observe(desiredState: desiredState)
    }

    public func plan(
        desiredState: DesiredRuntimeState,
        observedState: ObservedRuntimeState
    ) async throws -> RuntimePlan {
        try await base.plan(
            desiredState: desiredState,
            observedState: observedState
        )
    }

    public func logs(
        for service: ObservedRuntimeService,
        tail: Int
    ) async throws -> RuntimeLogResult {
        try await base.logs(for: service, tail: tail)
    }

    public func runtimeVersion() async throws -> String {
        try await base.runtimeVersion()
    }

    public func runtimeReadiness() async throws -> RuntimeReadinessReport {
        try await base.runtimeReadiness()
    }

    public func localImageEvidence(
        for imageReference: String
    ) async throws -> RuntimeLocalImageEvidence {
        try await base.localImageEvidence(for: imageReference)
    }

    public func resourceUsage(
        for resourceIdentifier: String
    ) async throws -> RuntimeResourceUsageSnapshot {
        try await base.resourceUsage(for: resourceIdentifier)
    }

    public func execute(
        _ action: PlannedRuntimeAction,
        confirmation: RuntimeMutationConfirmation?
    ) async throws -> RuntimeEvent {
        try await base.execute(action, confirmation: confirmation)
    }

    public func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        let identity = try await runtimeIdentity()
        let operations = RuntimeImageLifecycleOperation.allCases.map {
            RuntimeImageOperationCapability(
                operation: $0,
                state: .available,
                reason: .implemented
            )
        }
        return try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerCLI,
            capabilitySHA256: Self.capabilitySHA256(identity: identity),
            operations: operations
        )
    }

    public func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        try Task.checkCancellation()
        let capability = try await imageOperationCapabilities()
        try capability.requireAvailable(request.operation)
        guard request.capabilitySHA256 == capability.capabilitySHA256 else {
            throw RuntimeImageLifecycleContractError.invalidCapabilitySHA256
        }
        if request.offline,
           request.operation == .pull ||
            request.operation == .push ||
            request.operation == .build {
            throw RuntimeImageLifecycleContractError.unavailable(
                operation: request.operation,
                reason: .policyBlocked
            )
        }
        let planSHA256 = try request.planSHA256()
        if request.operation != .inspect {
            guard confirmation?.confirmed == true,
                  confirmation?.planHash == planSHA256 else {
                throw RuntimeAdapterError.commandRejected(
                    classification: .mutating,
                    message: "Image mutation requires the exact confirmed request plan."
                )
            }
        }

        var emitter = ImageProgressEmitter(request: request, emit: progress)
        try await emitter.send(stage: .resolving)
        let identity = try await runtimeIdentity()
        let executable = try resolvedExecutable()
        let before = try await preOperationObservation(
            request,
            executable: executable
        )
        if request.operation == .inspect {
            try await emitter.send(stage: .complete)
            return try result(
                request: request,
                providerVersion: identity.version,
                images: before,
                disposition: .unchanged
            )
        }
        try Self.requireExpectedSourceDigests(
            request,
            observed: before
        )
        if (request.operation == .delete || request.operation == .prune),
           request.sourceReferences.isEmpty {
            try await emitter.send(stage: .complete)
            return try result(
                request: request,
                providerVersion: identity.version,
                images: [],
                disposition: .unchanged
            )
        }

        try Task.checkCancellation()
        try await emitter.send(stage: progressStage(for: request.operation))
        let spec = try mutationSpec(request, executable: executable)
        try RuntimeCommandPolicy.validateImageLifecycleMutation(spec)
        let mutationOutput: RuntimeCommandResult
        do {
            mutationOutput = try await processRunner.run(spec)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeAdapterError {
            throw Self.sanitizedMutationError(
                error,
                operation: request.operation
            )
        } catch {
            throw RuntimeAdapterError.commandFailed(
                exitStatus: -1,
                message: "Image lifecycle mutation failed at the bounded provider boundary.",
                standardError: ""
            )
        }
        try discardMutationOutput(
            mutationOutput,
            maximumBytes: request.maximumOutputBytes
        )
        try Task.checkCancellation()
        try await emitter.send(stage: .verifying)
        let after = try await postOperationObservation(
            request,
            before: before,
            executable: executable
        )
        try await emitter.send(stage: .complete)

        let deletedDigests: [String]
        if request.operation == .delete || request.operation == .prune {
            deletedDigests = Array(Set(before.map(\.digest))).sorted()
        } else {
            deletedDigests = []
        }
        return try result(
            request: request,
            providerVersion: identity.version,
            images: after,
            deletedDigests: deletedDigests,
            disposition: before == after ? .unchanged : .succeeded
        )
    }

    private func preOperationObservation(
        _ request: RuntimeImageLifecycleRequest,
        executable: ResolvedRuntimeExecutable
    ) async throws -> [RuntimeImageRecord] {
        switch request.operation {
        case .pull, .build:
            return try await observeIfPresent(
                references: request.operation == .build
                    ? [request.targetReference!]
                    : request.sourceReferences,
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
        case .load:
            return try await observeAll(
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
        case .push, .tag, .save, .delete, .prune, .inspect:
            return try await observeRequired(
                references: request.sourceReferences,
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
        }
    }

    private func postOperationObservation(
        _ request: RuntimeImageLifecycleRequest,
        before: [RuntimeImageRecord],
        executable: ResolvedRuntimeExecutable
    ) async throws -> [RuntimeImageRecord] {
        switch request.operation {
        case .pull:
            return try await observeRequired(
                references: request.sourceReferences,
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
        case .build:
            return try await observeRequired(
                references: [request.targetReference!],
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
        case .load:
            let after = try await observeAll(
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
            return try await verifiedLoadResult(
                request: request,
                before: before,
                after: after,
                executable: executable
            )
        case .tag:
            let result = try await observeRequired(
                references: [request.targetReference!],
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
            guard Set(result.map(\.digest)) == Set(before.map(\.digest)) else {
                throw RuntimeImageLifecycleContractError.invalidResult
            }
            return result
        case .push, .save:
            let result = try await observeRequired(
                references: request.sourceReferences,
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
            guard Set(result.map(\.digest)) == Set(before.map(\.digest)) else {
                throw RuntimeImageLifecycleContractError.invalidResult
            }
            if request.operation == .save {
                try Self.requireNewRegularArchive(request.archivePath!)
            }
            return result
        case .delete, .prune:
            let remaining = try await observeIfPresent(
                references: request.sourceReferences,
                executable: executable,
                maximumBytes: request.maximumOutputBytes
            )
            guard remaining.isEmpty else {
                throw RuntimeImageLifecycleContractError.invalidResult
            }
            return []
        case .inspect:
            return before
        }
    }

    private func mutationSpec(
        _ request: RuntimeImageLifecycleRequest,
        executable: ResolvedRuntimeExecutable
    ) throws -> RuntimeCommandSpec {
        var arguments: [String]
        let platform = Self.platformString(request)
        switch request.operation {
        case .pull, .push:
            arguments = [
                "image",
                request.operation.rawValue,
                "--scheme",
                "https",
                "--progress",
                "none"
            ]
            if let platform {
                arguments += ["--platform", platform]
            }
            arguments.append(request.sourceReferences[0])
        case .tag:
            arguments = [
                "image",
                "tag",
                request.sourceReferences[0],
                request.targetReference!
            ]
        case .load:
            try Self.requireExistingRegularArchive(request.archivePath!)
            arguments = ["image", "load", "--input", request.archivePath!]
        case .save:
            try Self.requireAbsentArchive(request.archivePath!)
            arguments = ["image", "save", "--output", request.archivePath!]
            if let platform {
                arguments += ["--platform", platform]
            }
            arguments += request.sourceReferences
        case .build:
            try Self.requireBuildInputs(
                contextPath: request.contextPath!,
                dockerfilePath: request.dockerfilePath
            )
            arguments = [
                "build",
                "--tag",
                request.targetReference!,
                "--quiet"
            ]
            if let dockerfilePath = request.dockerfilePath {
                arguments += ["--file", dockerfilePath]
            }
            if let platform {
                arguments += ["--platform", platform]
            }
            if request.noCache {
                arguments.append("--no-cache")
            }
            arguments.append(request.contextPath!)
        case .delete, .prune:
            arguments = ["image", "delete"] + request.sourceReferences
        case .inspect:
            throw RuntimeImageLifecycleContractError.unexpectedField(
                operation: .inspect,
                field: "mutation"
            )
        }
        return RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments,
            workingDirectory: "/",
            timeout: RuntimeCommandTimeout(
                seconds: RuntimeCommandTimeout.maximumSeconds
            ),
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .imageLifecycle,
            purpose: "Apple container \(request.operation.rawValue) image lifecycle"
        )
    }

    private func observeRequired(
        references: [String],
        executable: ResolvedRuntimeExecutable,
        maximumBytes: Int
    ) async throws -> [RuntimeImageRecord] {
        let observed = try await observeIfPresent(
            references: references,
            executable: executable,
            maximumBytes: maximumBytes
        )
        let observedReferences = Set(observed.flatMap(\.references))
        guard Set(references).isSubset(of: observedReferences) else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
        return observed
    }

    private func observeIfPresent(
        references: [String],
        executable: ResolvedRuntimeExecutable,
        maximumBytes: Int
    ) async throws -> [RuntimeImageRecord] {
        guard !references.isEmpty else {
            return []
        }
        let all = try await observeAll(
            executable: executable,
            maximumBytes: maximumBytes
        )
        let requested = Set(references)
        return all.filter { record in
            !requested.isDisjoint(with: record.references)
        }
    }

    private func observeAll(
        executable: ResolvedRuntimeExecutable,
        maximumBytes: Int
    ) async throws -> [RuntimeImageRecord] {
        let spec = RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: ["image", "list", "--format", "json"],
            workingDirectory: "/",
            timeout: RuntimeCommandTimeout(seconds: 60),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Observe Apple container images"
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let output = try await processRunner.run(spec).standardOutput
        guard output.utf8.count <= maximumBytes else {
            throw RuntimeImageLifecycleContractError.invalidOutputLimit
        }
        return try AppleImageRecordDecoder.decode(output)
    }

    private func verifiedLoadResult(
        request: RuntimeImageLifecycleRequest,
        before: [RuntimeImageRecord],
        after: [RuntimeImageRecord],
        executable: ResolvedRuntimeExecutable
    ) async throws -> [RuntimeImageRecord] {
        let beforeReferences = try Self.referenceDigests(before)
        let afterReferences = try Self.referenceDigests(after)
        let created = afterReferences.filter {
            beforeReferences[$0.key] == nil
        }
        let changedOrRemoved = beforeReferences.filter {
            afterReferences[$0.key] != $0.value
        }
        let expected = Set(request.sourceReferences)
        if changedOrRemoved.isEmpty,
           Set(created.keys) == expected {
            let selected = after.filter {
                !expected.isDisjoint(with: $0.references)
            }
            let selectedReferences = Set(selected.flatMap(\.references))
            guard expected.isSubset(of: selectedReferences) else {
                throw RuntimeImageLifecycleContractError.invalidResult
            }
            return selected
        }

        let createdEvidence = try created.map {
            try RuntimeImageReferenceDigest(
                reference: $0.key,
                digest: $0.value
            )
        }
        if !createdEvidence.isEmpty {
            do {
                let references = created.keys.sorted()
                let cleanup = RuntimeCommandSpec(
                    executablePath: executable.path,
                    arguments: ["image", "delete"] + references,
                    workingDirectory: "/",
                    timeout: RuntimeCommandTimeout(
                        seconds: RuntimeCommandTimeout.maximumSeconds
                    ),
                    classification: .mutating,
                    executableResolution:
                        .resolvedByRuntimeExecutableResolver,
                    mutationKind: .imageLifecycle,
                    purpose:
                        "Compensate undeclared Apple container load references"
                )
                try RuntimeCommandPolicy.validateImageLifecycleMutation(
                    cleanup
                )
                let output = try await processRunner.run(cleanup)
                try discardMutationOutput(
                    output,
                    maximumBytes: request.maximumOutputBytes
                )
                let restored = try await observeAll(
                    executable: executable,
                    maximumBytes: request.maximumOutputBytes
                )
                if changedOrRemoved.isEmpty,
                   try Self.referenceDigests(restored) == beforeReferences {
                    throw RuntimeImageLifecycleContractError.invalidResult
                }
            } catch let error as RuntimeImageLifecycleContractError {
                if error == .invalidResult {
                    throw error
                }
                throw try RuntimeImagePartialEffectError(
                    operation: .load,
                    createdReferences: createdEvidence,
                    unrestorableChange: !changedOrRemoved.isEmpty
                )
            } catch {
                throw try RuntimeImagePartialEffectError(
                    operation: .load,
                    createdReferences: createdEvidence,
                    unrestorableChange: !changedOrRemoved.isEmpty
                )
            }
            throw try RuntimeImagePartialEffectError(
                operation: .load,
                createdReferences: createdEvidence,
                unrestorableChange: true
            )
        }
        throw try RuntimeImagePartialEffectError(
            operation: .load,
            createdReferences: [],
            unrestorableChange: true
        )
    }

    private static func referenceDigests(
        _ records: [RuntimeImageRecord]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for record in records {
            for reference in record.references {
                if let existing = result[reference],
                   existing != record.digest {
                    throw RuntimeImageLifecycleContractError.invalidResult
                }
                result[reference] = record.digest
            }
        }
        return result
    }

    private static func requireExpectedSourceDigests(
        _ request: RuntimeImageLifecycleRequest,
        observed: [RuntimeImageRecord]
    ) throws {
        guard !request.expectedSourceDigests.isEmpty else {
            return
        }
        let actual = try referenceDigests(observed)
        guard request.expectedSourceDigests.allSatisfy({
            actual[$0.key] == $0.value
        }) else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
    }

    private func runtimeIdentity() async throws -> AppleContainerCLIIdentity {
        let executable = try resolvedExecutable()
        let spec = RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: ["--version"],
            workingDirectory: "/",
            timeout: RuntimeCommandTimeout(seconds: 15),
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Negotiate Apple container image provider version"
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let output = try await processRunner.run(spec).standardOutput
        _ = try AppleContainerCLICodec.selectForMutation(
            fromVersionOutput: output,
            redactionPolicy: redactionPolicy
        )
        guard let identity = AppleContainerVersionParser.parseCLIIdentity(output) else {
            throw RuntimeImageLifecycleContractError.invalidCapabilityContract
        }
        return identity
    }

    private func resolvedExecutable() throws -> ResolvedRuntimeExecutable {
        guard let executable = try executableResolver.resolveExecutable(
            named: AppleContainerCommand.executableName
        ) else {
            throw RuntimeAdapterError.runtimeUnavailable(
                "Apple container CLI was not found on PATH."
            )
        }
        return executable
    }

    private func result(
        request: RuntimeImageLifecycleRequest,
        providerVersion: String,
        images: [RuntimeImageRecord],
        deletedDigests: [String] = [],
        disposition: RuntimeImageOperationDisposition
    ) throws -> RuntimeImageOperationResult {
        try RuntimeImageOperationResult(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: .appleContainerCLI,
            providerVersion: providerVersion,
            disposition: disposition,
            images: images,
            deletedDigests: deletedDigests
        )
    }

    private func discardMutationOutput(
        _ result: RuntimeCommandResult,
        maximumBytes: Int
    ) throws {
        guard result.standardOutput.utf8.count <= maximumBytes,
              result.standardError.utf8.count <= maximumBytes else {
            throw RuntimeImageLifecycleContractError.invalidOutputLimit
        }
    }

    private func progressStage(
        for operation: RuntimeImageLifecycleOperation
    ) -> RuntimeImageProgressStage {
        switch operation {
        case .pull:
            .downloading
        case .build:
            .building
        case .push:
            .uploading
        case .tag, .load, .save:
            .writing
        case .delete, .prune:
            .deleting
        case .inspect:
            .resolving
        }
    }

    private static func platformString(
        _ request: RuntimeImageLifecycleRequest
    ) -> String? {
        guard let operatingSystem = request.platformOS,
              let architecture = request.platformArchitecture else {
            return nil
        }
        return "\(operatingSystem)/\(architecture)"
    }

    private static func sanitizedMutationError(
        _ error: RuntimeAdapterError,
        operation: RuntimeImageLifecycleOperation
    ) -> RuntimeAdapterError {
        let command = "Apple container \(operation.rawValue) image lifecycle"
        switch error {
        case .commandCancelled:
            return .commandCancelled(
                command: command,
                partialOutput: "",
                partialError: ""
            )
        case .commandTimedOut:
            return .commandTimedOut(
                command: command,
                partialOutput: "",
                partialError: ""
            )
        case .commandOutputLimitExceeded:
            return .commandOutputLimitExceeded(
                command: command,
                partialOutput: "",
                partialError: ""
            )
        case .commandProcessTreeViolation:
            return .commandProcessTreeViolation(
                command: command,
                partialOutput: "",
                partialError: ""
            )
        case .commandRejected:
            return .commandRejected(
                classification: .mutating,
                message: "Image lifecycle mutation was rejected at the bounded provider boundary."
            )
        default:
            return .commandFailed(
                exitStatus: -1,
                message: "Image lifecycle mutation failed at the bounded provider boundary.",
                standardError: ""
            )
        }
    }

    private static func capabilitySHA256(
        identity: AppleContainerCLIIdentity
    ) -> String {
        let value = [
            "provider=apple-container-cli",
            "version=\(identity.version)",
            "build=\(identity.build)",
            "commit=\(identity.commit)",
            "contract=\(RuntimeImageOperationCapabilityContract.currentSchemaVersion)",
            "operations=\(RuntimeImageLifecycleOperation.allCases.map(\.rawValue).sorted().joined(separator: ","))"
        ].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func requireExistingRegularArchive(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw RuntimeImageLifecycleContractError.invalidPath(path)
        }
    }

    private static func requireAbsentArchive(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) != 0, errno == ENOENT else {
            throw RuntimeImageLifecycleContractError.invalidPath(path)
        }
        try requireSafeParent(of: path)
    }

    private static func requireNewRegularArchive(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw RuntimeImageLifecycleContractError.invalidPath(path)
        }
    }

    private static func requireBuildInputs(
        contextPath: String,
        dockerfilePath: String?
    ) throws {
        var context = stat()
        guard lstat(contextPath, &context) == 0,
              (context.st_mode & S_IFMT) == S_IFDIR,
              (context.st_uid == geteuid() || context.st_uid == 0),
              context.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw RuntimeImageLifecycleContractError.invalidPath(contextPath)
        }
        if let dockerfilePath {
            var file = stat()
            guard lstat(dockerfilePath, &file) == 0,
                  (file.st_mode & S_IFMT) == S_IFREG,
                  (file.st_uid == geteuid() || file.st_uid == 0),
                  file.st_nlink == 1,
                  file.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
                throw RuntimeImageLifecycleContractError.invalidPath(
                    dockerfilePath
                )
            }
        }
    }

    private static func requireSafeParent(of path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(parent, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0 else {
            throw RuntimeImageLifecycleContractError.invalidPath(path)
        }
    }
}

private struct ImageProgressEmitter: Sendable {
    let request: RuntimeImageLifecycleRequest
    let emit: @Sendable (RuntimeImageProgressEvent) async -> Void
    private var sequence: UInt64 = 0

    init(
        request: RuntimeImageLifecycleRequest,
        emit: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) {
        self.request = request
        self.emit = emit
    }

    mutating func send(stage: RuntimeImageProgressStage) async throws {
        let event = try RuntimeImageProgressEvent(
            operation: request.operation,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            sequence: sequence,
            stage: stage,
            completedBytes: 0
        )
        sequence += 1
        await emit(event)
    }
}

private enum AppleImageRecordDecoder {
    static func decode(_ text: String) throws -> [RuntimeImageRecord] {
        guard let data = text.data(using: .utf8) else {
            throw RuntimeImageLifecycleContractError.invalidImageRecord
        }
        let payloads: [AppleImagePayload]
        do {
            payloads = try JSONDecoder().decode(
                [AppleImagePayload].self,
                from: data
            )
        } catch {
            throw RuntimeImageLifecycleContractError.invalidImageRecord
        }
        let grouped = Dictionary(grouping: payloads, by: {
            $0.configuration.descriptor.digest
        })
        return try grouped.keys.sorted().map { digest in
            let values = grouped[digest]!
            let first = values[0]
            guard values.allSatisfy({
                $0.configuration.descriptor == first.configuration.descriptor &&
                    $0.variants == first.variants
            }) else {
                throw RuntimeImageLifecycleContractError.invalidImageRecord
            }
            let references = values.map(\.configuration.name)
            let variants = try first.variants.map { value in
                try RuntimeImageVariantRecord(
                    digest: value.digest,
                    operatingSystem: value.platform.os,
                    architecture: value.platform.architecture,
                    sizeBytes: value.size,
                    layerDigests: value.config?.rootfs?.diffIDs ?? []
                )
            }
            return try RuntimeImageRecord(
                digest: digest,
                references: references,
                mediaType: first.configuration.descriptor.mediaType,
                sizeBytes: first.configuration.descriptor.size,
                variants: variants,
                createdAtUnixSeconds: first.configuration.creationDate.flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }.map { Int64($0.timeIntervalSince1970) }
            )
        }
    }
}

private struct AppleImagePayload: Decodable, Equatable {
    struct Configuration: Decodable, Equatable {
        struct Descriptor: Decodable, Equatable {
            let digest: String
            let mediaType: String
            let size: Int64
        }

        let creationDate: String?
        let descriptor: Descriptor
        let name: String
    }

    struct Variant: Decodable, Equatable {
        struct Platform: Decodable, Equatable {
            let architecture: String
            let os: String
        }

        struct Config: Decodable, Equatable {
            struct RootFS: Decodable, Equatable {
                let diffIDs: [String]

                private enum CodingKeys: String, CodingKey {
                    case diffIDs = "diff_ids"
                }
            }

            let rootfs: RootFS?
        }

        let config: Config?
        let digest: String
        let platform: Platform
        let size: Int64
    }

    let configuration: Configuration
    let variants: [Variant]
}

extension AppleContainerizationRuntimeAdapter: RuntimeImageLifecycleProviding {
    public func imageOperationCapabilities()
        async throws -> RuntimeImageOperationCapabilityContract
    {
        let snapshot = try await capabilitySnapshot()
        let operations = RuntimeImageLifecycleOperation.allCases.map { operation in
            RuntimeImageOperationCapability(
                operation: operation,
                state: operation == .inspect ? .available : .unavailable,
                reason: operation == .inspect ? .implemented : .providerUnsupported
            )
        }
        return try RuntimeImageOperationCapabilityContract(
            providerID: .appleContainerization,
            capabilitySHA256: snapshot.canonicalSHA256,
            operations: operations
        )
    }

    public func performImageOperation(
        _ request: RuntimeImageLifecycleRequest,
        confirmation: RuntimeMutationConfirmation?,
        progress: @escaping @Sendable (RuntimeImageProgressEvent) async -> Void
    ) async throws -> RuntimeImageOperationResult {
        let capability = try await imageOperationCapabilities()
        try capability.requireAvailable(request.operation)
        guard request.operation == .inspect,
              request.capabilitySHA256 == capability.capabilitySHA256,
              confirmation == nil else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "The Containerization helper does not implement image mutation operations."
            )
        }
        let resolving = try RuntimeImageProgressEvent(
            operation: .inspect,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            sequence: 0,
            stage: .resolving,
            completedBytes: 0
        )
        await progress(resolving)
        let inventory = try await inventory()
        let requested = Set(request.sourceReferences)
        let selected = inventory.images.filter {
            !requested.isDisjoint(with: $0.references)
        }
        let observedReferences = Set(selected.flatMap(\.references))
        guard requested.isSubset(of: observedReferences) else {
            throw RuntimeImageLifecycleContractError.invalidResult
        }
        let records = try selected.map { image in
            try RuntimeImageRecord(
                digest: image.descriptorDigest,
                references: image.references,
                mediaType: "application/vnd.oci.image.index.v1+json",
                sizeBytes: 0,
                variants: try image.variants.map {
                    try RuntimeImageVariantRecord(
                        digest: $0.digest,
                        operatingSystem: $0.operatingSystem,
                        architecture: $0.architecture,
                        sizeBytes: 0
                    )
                }
            )
        }
        let complete = try RuntimeImageProgressEvent(
            operation: .inspect,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            sequence: 1,
            stage: .complete,
            completedBytes: 0
        )
        await progress(complete)
        return try RuntimeImageOperationResult(
            operation: .inspect,
            operationID: request.operationID,
            idempotencyKey: request.idempotencyKey,
            planSHA256: request.planSHA256(),
            providerID: .appleContainerization,
            providerVersion: try await runtimeVersion(),
            disposition: .unchanged,
            images: records
        )
    }
}
