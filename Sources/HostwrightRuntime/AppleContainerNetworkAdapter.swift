import Darwin
import Foundation

public enum AppleContainerNetworkCommand {
    public static func inspectSpec(
        identity: RuntimeNetworkIdentity,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        _ = codec
        return RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: ["network", "inspect", identity.runtimeIdentifier],
            timeout: timeout,
            classification: .readOnly,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            purpose: "Inspect exact Hostwright-owned Apple container network as JSON."
        )
    }

    public static func listSpec(
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) -> RuntimeCommandSpec {
        AppleContainerCommand.spec(
            kind: .listNetworks,
            codec: codec,
            executable: executable,
            timeout: timeout
        )
    }

    public static func createSpec(
        request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) throws -> RuntimeCommandSpec {
        guard context.providerID == .appleContainerCLI,
              context.resourceUUID == request.identity.resourceUUID,
              context.projectResourceUUID == request.identity.projectUUID,
              context.validationIssue == nil else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Apple network create requires exact Runtime Provider API v2 UUID and fencing context."
            )
        }
        _ = codec
        try validateAddressRequest(request.ipv4, family: .ipv4)
        try validateAddressRequest(request.ipv6, family: .ipv6)
        guard request.ipv4.mode != .disabled, request.ipv6.mode != .disabled else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Apple container CLI 1.0.0 and 1.1.0 do not expose a supported way to disable one network address family."
            )
        }

        var arguments = ["network", "create"]
        if request.mode == .hostOnly {
            arguments.append("--internal")
        }
        let labels = try RuntimeNetworkOwnership.labels(
            for: request.identity,
            context: context,
            userLabels: request.labels
        )
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            arguments += ["--label", "\(key)=\(value)"]
        }
        if case .cidr(let subnet) = request.ipv4 {
            arguments += ["--subnet", subnet]
        }
        if case .cidr(let subnet) = request.ipv6 {
            arguments += ["--subnet-v6", subnet]
        }
        arguments.append(request.identity.runtimeIdentifier)
        return RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: arguments,
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .networkLifecycle,
            purpose: "Create exact UUID-owned Apple container project network."
        )
    }

    public static func deleteSpec(
        request: RuntimeNetworkDeleteRequest,
        context: RuntimeMutationContext,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable,
        timeout: RuntimeCommandTimeout = RuntimeCommandTimeout()
    ) throws -> RuntimeCommandSpec {
        guard context.providerID == .appleContainerCLI,
              context.resourceUUID == request.identity.resourceUUID,
              context.projectResourceUUID == request.identity.projectUUID,
              context.validationIssue == nil else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Apple network delete requires exact Runtime Provider API v2 UUID and fencing context."
            )
        }
        _ = codec
        return RuntimeCommandSpec(
            executablePath: executable.path,
            arguments: ["network", "delete", request.identity.runtimeIdentifier],
            timeout: timeout,
            classification: .mutating,
            executableResolution: .resolvedByRuntimeExecutableResolver,
            mutationKind: .networkLifecycle,
            purpose: "Delete exact verified UUID-owned Apple container project network."
        )
    }

    private enum AddressFamily {
        case ipv4
        case ipv6

        var systemValue: Int32 {
            switch self {
            case .ipv4:
                return AF_INET
            case .ipv6:
                return AF_INET6
            }
        }

        var maximumPrefix: Int {
            switch self {
            case .ipv4:
                return 32
            case .ipv6:
                return 128
            }
        }
    }

    private static func validateAddressRequest(
        _ request: RuntimeNetworkAddressRequest,
        family: AddressFamily
    ) throws {
        guard case .cidr(let value) = request else { return }
        let components = value.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let prefix = Int(components[1]),
              (0...family.maximumPrefix).contains(prefix),
              value.utf8.count <= 128 else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Apple network create requires a valid bounded CIDR."
            )
        }
        var storage = in6_addr()
        let parsed = String(components[0]).withCString {
            inet_pton(family.systemValue, $0, &storage)
        }
        guard parsed == 1 else {
            throw RuntimeAdapterError.commandRejected(
                classification: .mutating,
                message: "Apple network create requires a CIDR matching the requested address family."
            )
        }
    }
}

public struct AppleContainerNetworkAdapter: Sendable {
    public let executableResolver: RuntimeExecutableResolving
    public let processRunner: RuntimeProcessRunning
    public let redactionPolicy: RuntimeRedactionPolicy

    public init(
        executableResolver: RuntimeExecutableResolving = RuntimeExecutableResolver(),
        processRunner: RuntimeProcessRunning = SecureRuntimeProcessRunner(),
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) {
        self.executableResolver = executableResolver
        self.processRunner = processRunner
        self.redactionPolicy = redactionPolicy
    }

    public func capabilities() async throws -> RuntimeNetworkProviderCapabilities {
        _ = try await resolvedCodec()
        return .appleContainerCLI
    }

    public func inspect(
        _ request: RuntimeNetworkInspectRequest
    ) async throws -> RuntimeNetworkOperationResult {
        let (executable, codec) = try await resolvedCodec()
        let evidence = try await inspectEvidence(
            request.identity,
            codec: codec,
            executable: executable
        )
        let ownership = try requireOwned(
            evidence,
            identity: request.identity,
            expectedContext: nil
        )
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: .inspect,
            networkRuntimeIdentifier: request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .present,
            verified: true,
            observedNetwork: inventoryNetwork(evidence, ownership: ownership)
        )
    }

    public func create(
        _ request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        let (executable, codec) = try await resolvedCodec()
        let spec = try AppleContainerNetworkCommand.createSpec(
            request: request,
            context: context,
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateNetworkLifecycleMutation(spec)
        let result = try await processRunner.run(spec)
        try codec.discardMutationOutput(result.standardOutput)

        let evidence = try await inspectEvidence(
            request.identity,
            codec: codec,
            executable: executable
        )
        let ownership = try RuntimeNetworkOwnership.verify(
            evidence,
            request: request,
            context: context
        )
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: .create,
            networkRuntimeIdentifier: request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .present,
            verified: true,
            observedNetwork: inventoryNetwork(evidence, ownership: ownership)
        )
    }

    public func delete(
        _ request: RuntimeNetworkDeleteRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        let (executable, codec) = try await resolvedCodec()
        let evidence = try await inspectEvidence(
            request.identity,
            codec: codec,
            executable: executable
        )
        _ = try requireOwned(
            evidence,
            identity: request.identity,
            expectedContext: context
        )

        let spec = try AppleContainerNetworkCommand.deleteSpec(
            request: request,
            context: context,
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateNetworkLifecycleMutation(spec)
        let result = try await processRunner.run(spec)
        try codec.discardMutationOutput(result.standardOutput)

        let listSpec = AppleContainerNetworkCommand.listSpec(
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(listSpec)
        let list = try codec.decodeNetworks(
            try await processRunner.run(listSpec).standardOutput,
            redactionPolicy: redactionPolicy
        )
        guard !list.contains(where: { $0.id == request.identity.runtimeIdentifier }) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container network remained present after exact deletion."
            )
        }
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerCLI,
            operation: .delete,
            networkRuntimeIdentifier: request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .missing,
            verified: true
        )
    }

    public func attach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        _ = request
        _ = context
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Apple container CLI supports network attachment only while creating a container; mutable attach is unavailable."
        )
    }

    public func detach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        _ = request
        _ = context
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "Apple container CLI does not expose a qualified mutable network detach operation."
        )
    }

    private func resolvedCodec() async throws -> (
        ResolvedRuntimeExecutable,
        AppleContainerCLICodec
    ) {
        guard let executable = try executableResolver.resolveExecutable(
            named: AppleContainerCommand.executableName
        ) else {
            throw RuntimeAdapterError.runtimeUnavailable(
                "Apple container CLI was not found on PATH."
            )
        }
        let codec = try await AppleContainerReadOnlyAdapter(
            executableResolver: executableResolver,
            processRunner: processRunner,
            redactionPolicy: redactionPolicy
        ).selectedCodec(executable: executable)
        return (executable, codec)
    }

    private func inspectEvidence(
        _ identity: RuntimeNetworkIdentity,
        codec: AppleContainerCLICodec,
        executable: ResolvedRuntimeExecutable
    ) async throws -> AppleContainerNetworkEvidence {
        let spec = AppleContainerNetworkCommand.inspectSpec(
            identity: identity,
            codec: codec,
            executable: executable
        )
        try RuntimeCommandPolicy.validateReadOnlyExecution(spec)
        let networks = try codec.decodeNetworks(
            try await processRunner.run(spec).standardOutput,
            redactionPolicy: redactionPolicy
        )
        guard networks.count == 1, let network = networks.first else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container network inspect must return exactly one structured network."
            )
        }
        return network
    }

    private func requireOwned(
        _ evidence: AppleContainerNetworkEvidence,
        identity: RuntimeNetworkIdentity,
        expectedContext: RuntimeMutationContext?
    ) throws -> RuntimeInventoryOwnershipEvidence {
        guard evidence.id == identity.runtimeIdentifier,
              evidence.name == identity.runtimeIdentifier,
              evidence.labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] ==
                identity.runtimeIdentifier,
              evidence.labels[RuntimeNetworkOwnership.resourceKindLabel] ==
                RuntimeNetworkOwnership.resourceKind,
              evidence.labels[RuntimeNetworkOwnership.networkNameLabel] ==
                identity.logicalName,
              let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
                  from: evidence.labels,
                  expectedProviderID: .appleContainerCLI
              ),
              ownership.resourceUUID == identity.resourceUUID,
              ownership.projectUUID == identity.projectUUID else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Apple network operation requires exact UUID-backed Hostwright ownership."
            )
        }
        if let expectedContext {
            guard expectedContext.validationIssue == nil,
                  expectedContext.providerID == .appleContainerCLI,
                  expectedContext.resourceUUID == ownership.resourceUUID,
                  expectedContext.projectResourceUUID == ownership.projectUUID,
                  expectedContext.resourceGeneration == ownership.resourceGeneration,
                  expectedContext.projectGeneration == ownership.projectGeneration,
                  expectedContext.providerGeneration == ownership.providerGeneration,
                  expectedContext.fencingToken == ownership.fencingToken else {
                throw RuntimeAdapterError.mutationUnavailableByPolicy(
                    "Apple network ownership or fencing evidence changed before mutation."
                )
            }
        }
        return ownership
    }

    private func inventoryNetwork(
        _ evidence: AppleContainerNetworkEvidence,
        ownership: RuntimeInventoryOwnershipEvidence
    ) -> RuntimeInventoryNetwork {
        RuntimeInventoryNetwork(
            runtimeID: evidence.id,
            name: evidence.name,
            kind: "\(evidence.plugin):\(evidence.mode.rawValue)",
            addresses: [evidence.ipv4Subnet, evidence.ipv4Gateway] +
                [evidence.ipv6Subnet].compactMap { $0 },
            labels: evidence.labels
                .map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
                .sorted {
                    ($0.key, $0.value) < ($1.key, $1.value)
                },
            ownership: ownership
        )
    }
}
