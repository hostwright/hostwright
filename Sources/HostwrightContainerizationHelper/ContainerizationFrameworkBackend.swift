import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightNetworking
import HostwrightRuntime
import vmnet

struct ContainerizationHelperResolvedProcess: Equatable, Sendable {
    let command: [String]
    let environment: [RuntimeInventoryEnvironmentEntry]
    let workingDirectory: String
    let user: String?
}

struct ContainerizationHelperImageRecord: Equatable, Sendable {
    let evidence: ContainerizationHelperImageEvidence
    let references: [String]
}

struct ContainerizationHelperRuntimeNetworkRecord: Equatable, Sendable {
    let identity: RuntimeNetworkIdentity
    let mode: RuntimeNetworkMode
    let ipv4Subnet: String
    let ipv4Gateway: String
    let ipv6Prefix: String?
    let ipv6Gateway: String?
    let labels: [String: String]

    func inventory() throws -> RuntimeInventoryNetwork {
        let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: labels,
            expectedProviderID: .appleContainerization
        )
        guard ownership != nil else {
            throw ContainerizationHelperBackendError.executionFailed(
                "managed network ownership evidence is missing"
            )
        }
        return RuntimeInventoryNetwork(
            runtimeID: identity.runtimeIdentifier,
            name: identity.runtimeIdentifier,
            kind: "vmnet:\(mode.rawValue)",
            addresses: [ipv4Subnet, ipv4Gateway] +
                [ipv6Prefix, ipv6Gateway].compactMap { $0 },
            labels: labels.map {
                RuntimeInventoryLabel(key: $0.key, value: $0.value)
            }.sorted {
                ($0.key, $0.value) < ($1.key, $1.value)
            },
            ownership: ownership
        )
    }
}

struct ContainerizationGuestNetworkPolicyEvidence:
    Equatable,
    Sendable
{
    let generation: Int
    let sha256: String
    let verified: Bool
}

private struct GuestPolicyLoaderResponse: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }

    let schema: Int
    let operation: ContainerizationGuestNetworkPolicyLoaderOperation
    let status: String
    let policyDigest: String?
    let generation: Int?
    let ruleCount: Int?
    let error: Failure?
}

private final class GuestPolicyBoundedBufferWriter:
    Writer,
    @unchecked Sendable
{
    private let maximumBytes: Int
    private let lock = NSLock()
    private var storage = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, maximumBytes - storage.count)
        if data.count > remaining {
            exceededLimit = true
        }
        storage.append(data.prefix(remaining))
    }

    func close() throws {}

    func snapshot() -> (data: Data, exceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (storage, exceededLimit)
    }
}

protocol ContainerizationHelperRuntimeDriving: Sendable {
    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess
    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence
    func listImages() async throws -> [ContainerizationHelperImageRecord]
    func listNetworks() async throws -> [ContainerizationHelperRuntimeNetworkRecord]
    func inspectNetwork(
        _ identity: RuntimeNetworkIdentity
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord?
    func createNetwork(
        _ request: RuntimeNetworkCreateRequest,
        labels: [String: String]
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord
    func deleteNetwork(_ identity: RuntimeNetworkIdentity) async throws
    func networkAttachments(
        resourceIdentifier: String
    ) async throws -> [RuntimeInventoryNetworkAttachment]
    func networkPolicyCapabilities()
        async -> RuntimeNetworkPolicyProviderCapabilities
    func reconcileNetworkPolicies(
        records: [ContainerizationHelperPersistedRecord]
    ) async throws -> [String: ContainerizationGuestNetworkPolicyEvidence]
    func create(
        _ record: ContainerizationHelperPersistedRecord,
        networks: [RuntimeDesiredNetworkAttachment]
    ) async throws
    func start(_ record: ContainerizationHelperPersistedRecord) async throws
    func restart(_ record: ContainerizationHelperPersistedRecord) async throws
    func stop(_ record: ContainerizationHelperPersistedRecord) async throws
    func delete(_ record: ContainerizationHelperPersistedRecord) async throws
    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage
    func shutdown() async
}

extension ContainerizationHelperRuntimeDriving {
    func networkPolicyCapabilities()
        async -> RuntimeNetworkPolicyProviderCapabilities {
        .unavailable
    }

    func reconcileNetworkPolicies(
        records: [ContainerizationHelperPersistedRecord]
    ) async throws -> [String: ContainerizationGuestNetworkPolicyEvidence] {
        [:]
    }
}

actor ContainerizationFrameworkBackend: ContainerizationHelperBackend {
    private let snapshot: RuntimeCapabilitySnapshot
    private let store: ContainerizationHelperStateStore
    private let driver: any ContainerizationHelperRuntimeDriving
    private var records: [String: ContainerizationHelperPersistedRecord]

    static func make(
        configuration: ContainerizationHelperConfiguration
    ) async throws -> ContainerizationFrameworkBackend {
        try configuration.validate()
        try ContainerizationHelperStateStore.preparePrivateDirectory(configuration.dataRootURL)
        let stateURL = configuration.dataRootURL.appendingPathComponent("state", isDirectory: true)
        let store = try ContainerizationHelperStateStore(rootURL: stateURL)
        let driver = try await AppleContainerizationRuntimeDriver(
            configuration: configuration,
            stateStore: store
        )
        return try ContainerizationFrameworkBackend(
            snapshot: try ContainerizationHelperCapabilitySnapshot.make(),
            store: store,
            driver: driver
        )
    }

    init(
        snapshot: RuntimeCapabilitySnapshot,
        store: ContainerizationHelperStateStore,
        driver: any ContainerizationHelperRuntimeDriving
    ) throws {
        self.snapshot = snapshot
        self.store = store
        self.driver = driver
        let loadedRecords = Dictionary(
            uniqueKeysWithValues: try store.loadRecords().map { ($0.resourceIdentifier, $0) }
        )
        self.records = try Self.recoverInterruptedState(loadedRecords, store: store)
    }
}

private extension AppleContainerizationRuntimeDriver {
    private func desiredGuestPolicy(
        for record: ContainerizationHelperPersistedRecord
    ) throws -> ContainerizationGuestNetworkPolicy {
        guard let policy = record.networkPolicy,
              let identity = try managedIdentity(for: record) else {
            throw ContainerizationHelperBackendError.rejected(
                "Guest network policy requires exact managed service identity."
            )
        }
        let baseGeneration = max(
            record.networkPolicyGeneration ?? 0,
            appliedGuestPolicies[record.resourceIdentifier]?.generation ?? 0
        )
        let candidateGeneration = max(1, baseGeneration)
        let candidate = try compileGuestPolicy(
            record: record,
            identity: identity,
            policy: policy,
            generation: candidateGeneration
        )
        if candidate.sha256 == record.networkPolicySHA256 ||
            candidate.sha256 ==
                appliedGuestPolicies[record.resourceIdentifier]?.sha256 {
            return candidate
        }
        guard baseGeneration > 0 else {
            return candidate
        }
        return try compileGuestPolicy(
            record: record,
            identity: identity,
            policy: policy,
            generation: baseGeneration + 1
        )
    }

    private func compileGuestPolicy(
        record: ContainerizationHelperPersistedRecord,
        identity: RuntimeServiceIdentity,
        policy: HostwrightServiceNetworkPolicy,
        generation: Int
    ) throws -> ContainerizationGuestNetworkPolicy {
        let peers = try policyRecords.values.sorted {
            $0.resourceIdentifier < $1.resourceIdentifier
        }.map { peerRecord -> ContainerizationGuestNetworkPeer in
            guard let peerIdentity = try managedIdentity(
                for: peerRecord
            ) else {
                throw ContainerizationHelperBackendError.rejected(
                    "A managed peer has incomplete ownership identity."
                )
            }
            let workloadIdentity = try HostwrightMutualTLSIdentity(
                projectUUID: peerRecord.projectUUID,
                resourceUUID: peerRecord.resourceUUID,
                role: .workload,
                generation:
                    peerRecord.mutationContext.resourceGeneration
            )
            return try ContainerizationGuestNetworkPeer(
                projectName: peerIdentity.projectName,
                projectUUID: peerRecord.projectUUID,
                serviceName: peerIdentity.serviceName,
                resourceUUID: peerRecord.resourceUUID,
                identities: [workloadIdentity.uriSAN],
                assignedAddresses:
                    observedNetworkAttachments[
                        peerRecord.resourceIdentifier
                    ]?.flatMap(\.addresses) ?? []
            )
        }
        let dnsNames = Set(
            (policy.ingress + policy.egress).compactMap(\.dns)
        )
        let resolutions = try ContainerizationGuestDNSResolutionMap(
            Dictionary(
                uniqueKeysWithValues: dnsNames.sorted().map {
                    ($0, Self.resolveHostAddresses($0))
                }
            )
        )
        let attachments =
            observedNetworkAttachments[record.resourceIdentifier] ?? []
        let gateways = attachments.compactMap(\.gateway)
        let inputs = try ContainerizationGuestNetworkPolicyInputs(
            peers: peers,
            dnsResolutions: resolutions,
            dnsServers: gateways,
            trustedIngressGateways: gateways
        )
        return try ContainerizationGuestNetworkPolicyCompiler.compile(
            projectName: identity.projectName,
            projectUUID: record.projectUUID,
            generation: generation,
            serviceName: identity.serviceName,
            serviceResourceUUID: record.resourceUUID,
            policy: policy,
            inputs: inputs
        )
    }

    private func managedIdentity(
        for record: ContainerizationHelperPersistedRecord
    ) throws -> RuntimeServiceIdentity? {
        var labels: [String: String] = [:]
        for label in record.labels {
            guard labels.updateValue(
                label.value,
                forKey: label.key
            ) == nil else {
                throw ContainerizationHelperBackendError.rejected(
                    "Managed resource labels contain duplicate keys."
                )
            }
        }
        guard let identity =
                RuntimeManagedResourceIdentity.identity(from: labels),
              identity.serviceName == record.logicalServiceName,
              labels[
                RuntimeManagedResourceIdentity.resourceUUIDLabel
              ] == record.resourceUUID,
              labels[
                RuntimeManagedResourceIdentity.projectUUIDLabel
              ] == record.projectUUID else {
            return nil
        }
        return identity
    }

    private func writeBootstrapPolicy(
        _ policy: ContainerizationGuestNetworkPolicy,
        for record: ContainerizationHelperPersistedRecord,
        using store: ContainerizationGuestPolicyStore
    ) throws {
        let target = try Self.numericTargetIdentity(record.user)
        _ = try store.prepareShare(
            resourceIdentifier: record.resourceIdentifier,
            request: ContainerizationGuestNetworkPolicyLoaderRequest(
                operation: .apply,
                policy: policy,
                targetUID: target.uid,
                targetGID: target.gid,
                workingDirectory: record.workingDirectory ?? "/"
            )
        )
    }

    private func applyGuestPolicy(
        _ policy: ContainerizationGuestNetworkPolicy,
        to resourceIdentifier: String,
        using store: ContainerizationGuestPolicyStore
    ) async throws {
        let request = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .apply,
            policy: policy
        )
        try store.writeUpdateRequest(
            request,
            resourceIdentifier: resourceIdentifier
        )
        try await runGuestPolicyLoader(
            request,
            resourceIdentifier: resourceIdentifier,
            acceptedStatuses: ["applied", "unchanged"]
        )
    }

    private func removeGuestPolicy(
        _ policy: ContainerizationGuestNetworkPolicy,
        from resourceIdentifier: String,
        using store: ContainerizationGuestPolicyStore
    ) async throws {
        let request = ContainerizationGuestNetworkPolicyLoaderRequest(
            operation: .remove,
            policy: policy
        )
        try store.writeUpdateRequest(
            request,
            resourceIdentifier: resourceIdentifier
        )
        try await runGuestPolicyLoader(
            request,
            resourceIdentifier: resourceIdentifier,
            acceptedStatuses: ["absent", "removed"]
        )
    }

    private func runGuestPolicyLoader(
        _ request: ContainerizationGuestNetworkPolicyLoaderRequest,
        resourceIdentifier: String,
        acceptedStatuses: Set<String>
    ) async throws {
        guard runningPolicyResources.contains(resourceIdentifier),
              let container = containers[resourceIdentifier] else {
            throw ContainerizationHelperBackendError.conflict(
                "Guest network policy requires a running exact resource."
            )
        }
        let stdout = GuestPolicyBoundedBufferWriter(
            maximumBytes: 64 * 1_024
        )
        let stderr = GuestPolicyBoundedBufferWriter(
            maximumBytes: 64 * 1_024
        )
        let process = try await container.exec(
            "hostwright-policy-" +
                UUID().uuidString.lowercased()
        ) { configuration in
            configuration.arguments = [
                ContainerizationGuestPolicyAsset.guestLoaderPath,
                "--guest-agent-request-file",
                ContainerizationGuestPolicyAsset
                    .guestUpdateRequestPath
            ]
            configuration.workingDirectory = "/"
            configuration.user = User(uid: 0, gid: 0)
            configuration.noNewPrivileges = true
            configuration.capabilities = LinuxCapabilities(
                capabilities: [.netAdmin]
            )
            configuration.stdout = stdout
            configuration.stderr = stderr
        }
        do {
            try Task.checkCancellation()
            try await process.start()
            let status = try await process.wait(
                timeoutInSeconds: 15
            )
            try await process.delete()
            try Task.checkCancellation()
            let stdoutSnapshot = stdout.snapshot()
            let stderrSnapshot = stderr.snapshot()
            guard status.exitCode == 0,
                  !stdoutSnapshot.exceededLimit,
                  !stderrSnapshot.exceededLimit else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "Guest network-policy loader failed with exit " +
                        "\(status.exitCode): " +
                        Self.boundedDiagnostic(stderrSnapshot.data)
                )
            }
            let response = try JSONDecoder().decode(
                GuestPolicyLoaderResponse.self,
                from: stdoutSnapshot.data
            )
            guard response.schema == 1,
                  response.operation == request.operation,
                  acceptedStatuses.contains(response.status),
                  response.policyDigest == request.policyDigest,
                  response.generation == request.generation,
                  response.error == nil else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "Guest network-policy loader returned mismatched evidence."
                )
            }
        } catch {
            try? await process.kill(Signal.kill)
            try? await process.delete()
            throw error
        }
    }

    private func compensateGuestPolicyChanges(
        _ changed:
            [(String, ContainerizationGuestNetworkPolicy?)],
        store: ContainerizationGuestPolicyStore
    ) async {
        for (resourceIdentifier, prior) in changed.reversed() {
            do {
                if let prior {
                    let currentGeneration =
                        appliedGuestPolicies[resourceIdentifier]?
                        .generation ?? prior.generation
                    let restored = try Self.copyPolicy(
                        prior,
                        generation: currentGeneration + 1
                    )
                    try await applyGuestPolicy(
                        restored,
                        to: resourceIdentifier,
                        using: store
                    )
                    appliedGuestPolicies[resourceIdentifier] =
                        restored
                } else if let current =
                    appliedGuestPolicies[resourceIdentifier] {
                    try await removeGuestPolicy(
                        current,
                        from: resourceIdentifier,
                        using: store
                    )
                    appliedGuestPolicies.removeValue(
                        forKey: resourceIdentifier
                    )
                }
            } catch {
                if let container = containers.removeValue(
                    forKey: resourceIdentifier
                ) {
                    try? await container.stop()
                }
                runningPolicyResources.remove(resourceIdentifier)
                appliedGuestPolicies.removeValue(
                    forKey: resourceIdentifier
                )
                try? releaseNetworkInterfaces(
                    resourceIdentifier: resourceIdentifier
                )
            }
        }
    }

    private static func copyPolicy(
        _ policy: ContainerizationGuestNetworkPolicy,
        generation: Int
    ) throws -> ContainerizationGuestNetworkPolicy {
        try ContainerizationGuestNetworkPolicy(
            generation: generation,
            projectUUID: policy.projectUUID,
            serviceResourceUUID: policy.serviceResourceUUID,
            ingressDefault: policy.ingressDefault,
            egressDefault: policy.egressDefault,
            dnsServers: policy.dnsServers,
            ingress: policy.ingress,
            egress: policy.egress
        )
    }

    private static func numericTargetIdentity(
        _ raw: String?
    ) throws -> (uid: UInt32?, gid: UInt32?) {
        guard let raw, !raw.isEmpty else {
            return (nil, nil)
        }
        let components = raw.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard (1...2).contains(components.count),
              let uid = UInt32(components[0]),
              uid <= 2_147_483_647 else {
            throw ContainerizationHelperBackendError.unavailable(
                "Guest network policy currently requires a numeric image user."
            )
        }
        if components.count == 1 {
            return (uid, 0)
        }
        guard let gid = UInt32(components[1]),
              gid <= 2_147_483_647 else {
            throw ContainerizationHelperBackendError.unavailable(
                "Guest network policy currently requires a numeric image group."
            )
        }
        return (uid, gid)
    }

    private static func resolveHostAddresses(
        _ hostname: String
    ) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var pointer: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &pointer) == 0
        else {
            return []
        }
        defer { freeaddrinfo(pointer) }
        var addresses = Set<String>()
        var current = pointer
        while let value = current {
            guard let address = value.pointee.ai_addr else {
                current = value.pointee.ai_next
                continue
            }
            var buffer = [CChar](
                repeating: 0,
                count: Int(NI_MAXHOST)
            )
            if getnameinfo(
                address,
                value.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let result = buffer.withUnsafeBufferPointer {
                    String(
                        decoding: $0.prefix { $0 != 0 }.map {
                            UInt8(bitPattern: $0)
                        },
                        as: UTF8.self
                    )
                }
                addresses.insert(result)
            }
            current = value.pointee.ai_next
        }
        return addresses.sorted()
    }

    private static func boundedDiagnostic(_ data: Data) -> String {
        let bounded = data.prefix(512)
        return String(decoding: bounded, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

extension ContainerizationFrameworkBackend {
    func negotiate() async throws -> RuntimeCapabilitySnapshot {
        snapshot
    }

    func observe(
        _ request: ContainerizationHelperObservePayload
    ) async throws -> ContainerizationHelperObservation {
        try Task.checkCancellation()
        try await finishPreparedDeletes()

        var containers: [RuntimeInventoryContainer] = []
        for record in records.values.sorted(by: { $0.resourceIdentifier < $1.resourceIdentifier }) {
            try Task.checkCancellation()
            let networkAttachments = try await driver.networkAttachments(
                resourceIdentifier: record.resourceIdentifier
            )
            let usage: RuntimeInventoryUsage?
            if request.includeResourceUsage, record.phase == .running {
                let value = try await driver.usage(resourceIdentifier: record.resourceIdentifier)
                usage = RuntimeInventoryUsage(
                    cpuUsageMicroseconds: value.cpuUsageMicroseconds,
                    memoryUsageBytes: value.memoryUsageBytes,
                    memoryLimitBytes: value.memoryLimitBytes,
                    networkReceiveBytes: value.networkReceiveBytes,
                    networkTransmitBytes: value.networkTransmitBytes,
                    blockReadBytes: value.blockReadBytes,
                    blockWriteBytes: value.blockWriteBytes,
                    processCount: value.processCount
                )
            } else {
                usage = nil
            }
            containers.append(
                try inventoryContainer(
                    record,
                    usage: usage,
                    networkAttachments: networkAttachments
                )
            )
        }

        let images = try await driver.listImages().map { image in
            RuntimeInventoryImage(
                runtimeID: image.evidence.descriptorDigest,
                descriptorDigest: image.evidence.descriptorDigest,
                references: image.references,
                variants: [
                    RuntimeInventoryImageVariant(
                        digest: image.evidence.variantDigest,
                        architecture: image.evidence.architecture,
                        operatingSystem: image.evidence.operatingSystem
                    )
                ],
                labels: []
            )
        }
        let inventory = try RuntimeInventoryBuilder.build(
            machine: RuntimeInventoryMachine(
                state: .running,
                operatingSystem: "macOS",
                architecture: "arm64",
                runtimeVersion: ContainerizationHelperConfiguration.frameworkVersion,
                services: [
                    RuntimeInventoryService(
                        identifier: "hostwright-containerization-helper",
                        state: .running,
                        required: true
                    )
                ]
            ),
            containers: containers,
            images: images,
            networks: try await driver.listNetworks().map { try $0.inventory() },
            volumes: []
        )
        return ContainerizationHelperObservation(inventory: inventory)
    }

    func localImageEvidence(
        _ request: ContainerizationHelperImageRequest
    ) async throws -> ContainerizationHelperImageEvidence {
        try Task.checkCancellation()
        do {
            return try await driver.localImageEvidence(reference: request.reference)
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            throw ContainerizationHelperBackendError.rejected("image is not available locally")
        }
    }

    func resourceUsage(
        _ request: ContainerizationHelperResourceRequest
    ) async throws -> ContainerizationHelperResourceUsage {
        try Task.checkCancellation()
        guard records[request.resourceIdentifier]?.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        return try await driver.usage(resourceIdentifier: request.resourceIdentifier)
    }

    func logs(_ request: ContainerizationHelperLogsRequest) async throws -> ContainerizationHelperLogs {
        try Task.checkCancellation()
        guard records[request.resourceIdentifier] != nil else {
            throw ContainerizationHelperBackendError.rejected("resource is not managed")
        }
        if request.cursor != nil || request.startAtEnd || request.maximumBytes != nil {
            let slice = try store.readLogSlice(
                resourceIdentifier: request.resourceIdentifier,
                lineLimit: request.lineLimit,
                cursor: request.cursor,
                startAtEnd: request.startAtEnd,
                maximumBytes: request.maximumBytes ?? RuntimeStreamEnvelope.maximumChunkBytes
            )
            return ContainerizationHelperLogs(
                resourceIdentifier: request.resourceIdentifier,
                text: String(decoding: slice.data, as: UTF8.self),
                lineLimit: request.lineLimit,
                cursorStart: slice.startOffset,
                cursorEnd: slice.endOffset,
                atCurrentEnd: slice.atCurrentEnd
            )
        }
        return ContainerizationHelperLogs(
            resourceIdentifier: request.resourceIdentifier,
            text: try store.readLog(
                resourceIdentifier: request.resourceIdentifier,
                lineLimit: request.lineLimit
            ),
            lineLimit: request.lineLimit
        )
    }

    func networkCapabilities() async throws -> RuntimeNetworkProviderCapabilities {
        RuntimeNetworkProviderCapabilities(
            providerID: .appleContainerization,
            operations: RuntimeNetworkProviderOperation.allCases.map { operation in
                let available: Bool
                switch operation {
                case .create, .inspect, .delete:
                    available = true
                case .attach, .detach:
                    available = false
                }
                return RuntimeNetworkOperationCapability(
                    operation: operation,
                    state: available ? .available : .unavailable,
                    reason: available ? .implemented : .notImplemented
                )
            },
            modes: RuntimeNetworkMode.allCases,
            ipv4AddressModes: [.cidr],
            ipv6AddressModes: [.disabled, .cidr],
            attachmentTiming: .containerCreateOnly,
            hostAccess: .guardedBroker,
            networkPolicy: await driver.networkPolicyCapabilities()
        )
    }

    func networkInspect(
        _ request: RuntimeNetworkInspectRequest
    ) async throws -> RuntimeNetworkOperationResult {
        try Task.checkCancellation()
        guard let record = try await driver.inspectNetwork(request.identity) else {
            throw ContainerizationHelperBackendError.rejected("network is not managed")
        }
        _ = try verifyNetwork(
            record,
            identity: request.identity,
            expectedContext: nil
        )
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerization,
            operation: .inspect,
            networkRuntimeIdentifier: request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .present,
            verified: true,
            observedNetwork: try record.inventory()
        )
    }

    func networkCreate(
        _ request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        try Task.checkCancellation()
        try validateNetworkMutation(identity: request.identity, context: context)
        guard request.ipv4.mode != .automatic else {
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not expose a qualified automatic IPv4 subnet allocator."
            )
        }
        guard request.ipv4.mode != .disabled else {
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork requires IPv4 addressing."
            )
        }
        guard request.ipv6.mode != .automatic else {
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not allocate an automatic IPv6 prefix."
            )
        }
        guard try await driver.inspectNetwork(request.identity) == nil else {
            throw ContainerizationHelperBackendError.conflict("network already exists")
        }
        let labels = try RuntimeNetworkOwnership.labels(
            for: request.identity,
            context: context,
            userLabels: request.labels
        )
        let created = try await driver.createNetwork(request, labels: labels)
        do {
            try Task.checkCancellation()
            guard let observed = try await driver.inspectNetwork(request.identity),
                  observed == created else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "network create was not observable"
                )
            }
            _ = try verifyNetworkCreate(
                observed,
                request: request,
                context: context
            )
            return RuntimeNetworkOperationResult(
                providerID: .appleContainerization,
                operation: .create,
                networkRuntimeIdentifier: request.identity.runtimeIdentifier,
                networkResourceUUID: request.identity.resourceUUID,
                state: .present,
                verified: true,
                observedNetwork: try observed.inventory()
            )
        } catch {
            if let current = try? await driver.inspectNetwork(request.identity),
               (try? verifyNetwork(
                   current,
                   identity: request.identity,
                   expectedContext: context
               )) != nil {
                try? await driver.deleteNetwork(request.identity)
            }
            throw error
        }
    }

    func networkAttach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        _ = request
        _ = context
        throw ContainerizationHelperBackendError.unavailable(
            "Containerization 0.35.0 binds network interfaces while creating the VM; mutable attach is unavailable."
        )
    }

    func networkDetach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        _ = request
        _ = context
        throw ContainerizationHelperBackendError.unavailable(
            "Containerization 0.35.0 binds network interfaces while creating the VM; mutable detach is unavailable."
        )
    }

    func networkDelete(
        _ request: RuntimeNetworkDeleteRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult {
        try Task.checkCancellation()
        try validateNetworkMutation(identity: request.identity, context: context)
        guard let observed = try await driver.inspectNetwork(request.identity) else {
            throw ContainerizationHelperBackendError.rejected("network is not managed")
        }
        if let expectedOwnership = request.expectedOwnership {
            try validateDeleteAuthority(
                expectedOwnership: expectedOwnership,
                identity: request.identity,
                context: context
            )
            let ownership = try verifyNetwork(
                observed,
                identity: request.identity,
                expectedContext: nil
            )
            guard ownership == expectedOwnership else {
                throw ContainerizationHelperBackendError.conflict(
                    "network ownership changed before fenced deletion"
                )
            }
        } else {
            _ = try verifyNetwork(
                observed,
                identity: request.identity,
                expectedContext: context
            )
        }
        try await driver.deleteNetwork(request.identity)
        try Task.checkCancellation()
        guard try await driver.inspectNetwork(request.identity) == nil else {
            throw ContainerizationHelperBackendError.executionFailed(
                "managed network remained present after deletion"
            )
        }
        return RuntimeNetworkOperationResult(
            providerID: .appleContainerization,
            operation: .delete,
            networkRuntimeIdentifier: request.identity.runtimeIdentifier,
            networkResourceUUID: request.identity.resourceUUID,
            state: .missing,
            verified: true
        )
    }

    func create(
        _ request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        try Task.checkCancellation()
        try validateCreateOwnership(request: request, context: context)
        try await validateCreateNetworks(request)
        if request.networkPolicy != nil {
            let policyCapabilities =
                await driver.networkPolicyCapabilities()
            guard policyCapabilities.state == .available,
                  Set(policyCapabilities.directions) ==
                    Set(HostwrightNetworkPolicyDirection.allCases),
                  policyCapabilities.enforcesExactIdentity,
                  policyCapabilities.enforcesCIDR,
                  policyCapabilities.enforcesDNS,
                  policyCapabilities.appliesAtomicGenerations,
                  policyCapabilities.observesRuleDigest else {
                throw ContainerizationHelperBackendError.unavailable(
                    "Containerization guest network-policy enforcement is unavailable"
                )
            }
        }
        guard records[request.resourceIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("resource already exists")
        }

        let resolved = try await driver.resolveProcess(for: request)
        guard !resolved.command.isEmpty else {
            throw ContainerizationHelperBackendError.rejected("image has no executable command")
        }
        var record = ContainerizationHelperPersistedRecord(request: request, context: context)
        record.command = resolved.command
        record.environment = resolved.environment
        record.workingDirectory = resolved.workingDirectory
        record.user = resolved.user
        try store.save(record)
        records[record.resourceIdentifier] = record

        do {
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            try await driver.create(record, networks: request.networks)
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            record.phase = .stopped
            record.failureCategory = nil
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .stopped)
        } catch {
            try? await driver.stop(record)
            record.phase = error is CancellationError ? .stopped : .failed
            record.failureCategory = error is CancellationError ? "cancelled" : "create-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func start(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard [.created, .stopped].contains(record.phase) else {
            throw ContainerizationHelperBackendError.conflict("resource cannot be started")
        }
        record.phase = .preparedStart
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            try await driver.start(record)
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            record.phase = .running
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .running)
        } catch {
            try? await driver.stop(record)
            record.phase = .stopped
            record.failureCategory = error is CancellationError ? "cancelled" : "start-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func stop(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard record.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        do {
            try Task.checkCancellation()
            try await driver.stop(record)
            try Task.checkCancellation()
            record.phase = .stopped
            record.failureCategory = nil
            try store.save(record)
            records[record.resourceIdentifier] = record
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            return result(for: record.resourceIdentifier, lifecycle: .stopped)
        } catch {
            record.failureCategory = error is CancellationError
                ? "cancelled"
                : record.phase == .stopped
                    ? "policy-reconcile-failed"
                    : "stop-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func restart(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        guard record.phase == .running else {
            throw ContainerizationHelperBackendError.conflict("resource is not running")
        }
        record.phase = .preparedRestart
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            try await driver.restart(record)
            try Task.checkCancellation()
            try await reconcileDriverNetworkPolicies()
            record = records[record.resourceIdentifier] ?? record
            record.runtimeInstanceID = UUID().uuidString.lowercased()
            record.phase = .running
            try store.save(record)
            records[record.resourceIdentifier] = record
            return result(for: record.resourceIdentifier, lifecycle: .running)
        } catch {
            try? await driver.stop(record)
            record.phase = .stopped
            record.failureCategory = error is CancellationError ? "cancelled" : "restart-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func delete(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) async throws -> ContainerizationHelperMutationResult {
        var record = try requireRecord(request, context: context)
        record.phase = .preparedDelete
        record.failureCategory = nil
        try store.save(record)
        records[record.resourceIdentifier] = record
        do {
            try Task.checkCancellation()
            try await driver.delete(record)
            try Task.checkCancellation()
            let remaining = records.values.filter {
                $0.resourceIdentifier != record.resourceIdentifier
            }
            let evidence = try await driver.reconcileNetworkPolicies(
                records: remaining
            )
            try persistNetworkPolicyEvidence(evidence)
            try store.removeLog(resourceIdentifier: record.resourceIdentifier)
            try store.removeRecord(resourceIdentifier: record.resourceIdentifier)
            records.removeValue(forKey: record.resourceIdentifier)
            return result(for: record.resourceIdentifier, lifecycle: .missing)
        } catch {
            record.failureCategory = error is CancellationError ? "cancelled" : "delete-failed"
            try store.save(record)
            records[record.resourceIdentifier] = record
            throw error
        }
    }

    func cancel(requestID: UUID) async {
        _ = requestID
    }

    func shutdown() async {
        for var record in records.values where record.phase == .running || record.phase == .created {
            do {
                try await driver.stop(record)
                record.phase = .stopped
                record.failureCategory = nil
                try store.save(record)
                records[record.resourceIdentifier] = record
            } catch {
                record.phase = .failed
                record.failureCategory = "shutdown-failed"
                try? store.save(record)
                records[record.resourceIdentifier] = record
            }
        }
        await driver.shutdown()
    }

    private static func recoverInterruptedState(
        _ records: [String: ContainerizationHelperPersistedRecord],
        store: ContainerizationHelperStateStore
    ) throws -> [String: ContainerizationHelperPersistedRecord] {
        var recovered = records
        for var record in records.values {
            switch record.phase {
            case .created, .preparedStart, .running, .preparedRestart:
                record.phase = .stopped
                record.failureCategory = "helper-restarted"
                try store.save(record)
                recovered[record.resourceIdentifier] = record
            case .preparedCreate:
                record.phase = .failed
                record.failureCategory = "interrupted-create"
                try store.save(record)
                recovered[record.resourceIdentifier] = record
            case .preparedDelete, .stopped, .failed:
                break
            }
        }
        return recovered
    }

    private func finishPreparedDeletes() async throws {
        for record in records.values where record.phase == .preparedDelete {
            try Task.checkCancellation()
            try await driver.delete(record)
            try store.removeLog(resourceIdentifier: record.resourceIdentifier)
            try store.removeRecord(resourceIdentifier: record.resourceIdentifier)
            records.removeValue(forKey: record.resourceIdentifier)
        }
    }

    private func requireRecord(
        _ request: ContainerizationHelperMutationPayload,
        context: RuntimeMutationContext
    ) throws -> ContainerizationHelperPersistedRecord {
        guard let record = records[request.resourceIdentifier],
              record.resourceUUID == request.resourceUUID.lowercased(),
              record.resourceUUID == context.resourceUUID.lowercased(),
              record.projectUUID == context.projectResourceUUID.lowercased(),
              record.mutationContext.resourceGeneration == context.resourceGeneration,
              record.mutationContext.projectGeneration == context.projectGeneration,
              record.mutationContext.providerGeneration == context.providerGeneration,
              record.mutationContext.fencingToken == context.fencingToken.lowercased() else {
            throw ContainerizationHelperBackendError.conflict("resource ownership or fence changed")
        }
        return record
    }

    private func validateCreateOwnership(
        request: ContainerizationHelperCreatePayload,
        context: RuntimeMutationContext
    ) throws {
        let labels = try labelDictionary(request.labels)
        guard let identity = RuntimeManagedResourceIdentity.identity(from: labels),
              identity.serviceName == request.logicalServiceName,
              request.networkPolicy.map({
                  HostwrightNetworkPolicyValidation.issue(in: $0) == nil
              }) ?? true,
              RuntimeManagedResourceIdentity.labelsMatch(
                labels,
                identity: identity,
                resourceIdentifier: request.resourceIdentifier
              ),
              let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: labels,
                expectedProviderID: .appleContainerization
              ),
              ownership.resourceUUID == context.resourceUUID.lowercased(),
              ownership.projectUUID == context.projectResourceUUID.lowercased(),
              ownership.resourceGeneration == context.resourceGeneration,
              ownership.projectGeneration == context.projectGeneration,
              ownership.providerGeneration == context.providerGeneration,
              ownership.fencingToken == context.fencingToken.lowercased() else {
            throw ContainerizationHelperBackendError.rejected("resource ownership labels are invalid")
        }
    }

    private func reconcileDriverNetworkPolicies() async throws {
        let evidence = try await driver.reconcileNetworkPolicies(
            records: records.values.sorted {
                $0.resourceIdentifier < $1.resourceIdentifier
            }
        )
        try persistNetworkPolicyEvidence(evidence)
    }

    private func persistNetworkPolicyEvidence(
        _ evidence:
            [String: ContainerizationGuestNetworkPolicyEvidence]
    ) throws {
        for resourceIdentifier in evidence.keys.sorted() {
            guard var record = records[resourceIdentifier],
                  let value = evidence[resourceIdentifier] else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "guest policy evidence referenced an unknown resource"
                )
            }
            record.networkPolicyGeneration = value.generation
            record.networkPolicySHA256 = value.sha256
            record.networkPolicyVerified = value.verified
            try store.save(record)
            records[resourceIdentifier] = record
        }
    }

    private func validateCreateNetworks(
        _ request: ContainerizationHelperCreatePayload
    ) async throws {
        var identifiers = Set<String>()
        let availableNetworks = try await driver.listNetworks()
        for attachment in request.networks {
            guard identifiers.insert(attachment.networkRuntimeIdentifier).inserted,
                  let listed = availableNetworks.first(where: {
                      $0.identity.runtimeIdentifier == attachment.networkRuntimeIdentifier
                  }),
                  let network = try await driver.inspectNetwork(listed.identity),
                  network.identity.runtimeIdentifier == attachment.networkRuntimeIdentifier,
                  network.identity.resourceUUID == attachment.networkResourceUUID,
                  network.identity.projectUUID == request.projectUUID else {
                throw ContainerizationHelperBackendError.rejected(
                    "requested network attachment is not an exact managed project network"
                )
            }
            _ = try verifyNetwork(
                network,
                identity: network.identity,
                expectedContext: nil
            )
        }
    }

    private func validateNetworkMutation(
        identity: RuntimeNetworkIdentity,
        context: RuntimeMutationContext
    ) throws {
        guard context.validationIssue == nil,
              context.providerID == .appleContainerization,
              context.resourceUUID == identity.resourceUUID,
              context.projectResourceUUID == identity.projectUUID else {
            throw ContainerizationHelperBackendError.rejected(
                "network mutation ownership context is invalid"
            )
        }
    }

    private func validateDeleteAuthority(
        expectedOwnership: RuntimeInventoryOwnershipEvidence,
        identity: RuntimeNetworkIdentity,
        context: RuntimeMutationContext
    ) throws {
        guard expectedOwnership.resourceUUID ==
                identity.resourceUUID,
              expectedOwnership.projectUUID ==
                identity.projectUUID,
              expectedOwnership.providerID ==
                context.providerID,
              expectedOwnership.providerGeneration ==
                context.providerGeneration,
              expectedOwnership.projectGeneration ==
                context.projectGeneration,
              context.resourceGeneration ==
                expectedOwnership.resourceGeneration + 1 else {
            throw ContainerizationHelperBackendError.rejected(
                "network delete prior ownership or new operation authority is invalid"
            )
        }
    }

    private func verifyNetworkCreate(
        _ record: ContainerizationHelperRuntimeNetworkRecord,
        request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) throws -> RuntimeInventoryOwnershipEvidence {
        let ownership = try verifyNetwork(
            record,
            identity: request.identity,
            expectedContext: context
        )
        guard record.mode == request.mode else {
            throw ContainerizationHelperBackendError.executionFailed(
                "network mode does not match the requested mode"
            )
        }
        switch request.ipv4 {
        case .automatic:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not expose a qualified automatic IPv4 subnet allocator."
            )
        case .disabled:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork requires IPv4 addressing."
            )
        case .cidr(let expected):
            guard record.ipv4Subnet == expected else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "observed IPv4 subnet differs from the requested CIDR"
                )
            }
        }
        switch request.ipv6 {
        case .automatic:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not allocate an automatic IPv6 prefix."
            )
        case .disabled:
            guard record.ipv6Prefix == nil,
                  record.ipv6Gateway == nil else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "observed IPv6 state exists although IPv6 was disabled"
                )
            }
        case .cidr(let expected):
            guard record.ipv6Prefix == expected else {
                throw ContainerizationHelperBackendError.executionFailed(
                    "observed IPv6 prefix differs from the requested CIDR"
                )
            }
        }
        return ownership
    }

    private func verifyNetwork(
        _ record: ContainerizationHelperRuntimeNetworkRecord,
        identity: RuntimeNetworkIdentity,
        expectedContext: RuntimeMutationContext?
    ) throws -> RuntimeInventoryOwnershipEvidence {
        guard record.identity == identity,
              record.labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] ==
                identity.runtimeIdentifier,
              record.labels[RuntimeNetworkOwnership.resourceKindLabel] ==
                RuntimeNetworkOwnership.resourceKind,
              record.labels[RuntimeNetworkOwnership.networkNameLabel] ==
                identity.logicalName,
              let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
                from: record.labels,
                expectedProviderID: .appleContainerization
              ),
              ownership.resourceUUID == identity.resourceUUID,
              ownership.projectUUID == identity.projectUUID else {
            throw ContainerizationHelperBackendError.rejected(
                "network ownership identity is invalid"
            )
        }
        if let expectedContext {
            guard ownership.resourceGeneration == expectedContext.resourceGeneration,
                  ownership.projectGeneration == expectedContext.projectGeneration,
                  ownership.providerGeneration == expectedContext.providerGeneration,
                  ownership.fencingToken == expectedContext.fencingToken else {
                throw ContainerizationHelperBackendError.conflict(
                    "network ownership or fence changed"
                )
            }
        }
        return ownership
    }

    private func labelDictionary(
        _ labels: [RuntimeInventoryLabel]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for label in labels {
            guard result.updateValue(label.value, forKey: label.key) == nil else {
                throw ContainerizationHelperBackendError.rejected("duplicate resource label")
            }
        }
        return result
    }

    private func inventoryContainer(
        _ record: ContainerizationHelperPersistedRecord,
        usage: RuntimeInventoryUsage?,
        networkAttachments: [RuntimeInventoryNetworkAttachment]
    ) throws -> RuntimeInventoryContainer {
        let labels = try labelDictionary(record.labels)
        let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: labels,
            expectedProviderID: .appleContainerization
        )
        let lifecycle: RuntimeInventoryLifecycleState
        switch record.phase {
        case .created:
            lifecycle = .created
        case .running:
            lifecycle = .running
        case .stopped:
            lifecycle = .stopped
        case .failed, .preparedCreate, .preparedStart, .preparedRestart, .preparedDelete:
            lifecycle = .failed
        }
        return RuntimeInventoryContainer(
            runtimeID: record.runtimeInstanceID ?? record.resourceIdentifier,
            name: record.resourceIdentifier,
            imageID: record.image.variantDigest,
            imageReference: record.image.reference,
            lifecycle: lifecycle,
            health: RuntimeInventoryHealth(availability: .unsupported),
            labels: record.labels,
            ownership: ownership,
            initConfiguration: RuntimeInventoryInitConfiguration(
                executable: record.command[0],
                arguments: Array(record.command.dropFirst()),
                environment: record.environment,
                workingDirectory: record.workingDirectory,
                user: record.user,
                terminal: false
            ),
            ports: [],
            mounts: [],
            networks: networkAttachments,
            allocation: RuntimeInventoryAllocation(cpuCount: 4, memoryBytes: 1_073_741_824),
            usage: usage,
            services: []
        )
    }

    private func result(
        for resourceIdentifier: String,
        lifecycle: RuntimeInventoryLifecycleState
    ) -> ContainerizationHelperMutationResult {
        ContainerizationHelperMutationResult(
            resourceIdentifier: resourceIdentifier,
            lifecycle: lifecycle,
            verified: true
        )
    }
}

@available(macOS 26.0, *)
private struct AppleContainerizationManagedNetwork: Sendable {
    var network: VmnetNetwork
    let record: ContainerizationHelperRuntimeNetworkRecord
}

private actor AppleContainerizationRuntimeDriver: ContainerizationHelperRuntimeDriving {
    private let configuration: ContainerizationHelperConfiguration
    private let stateStore: ContainerizationHelperStateStore
    private let imageStore: ImageStore
    private let guestPolicyStore: ContainerizationGuestPolicyStore?
    private var manager: ContainerManager
    private var containers: [String: LinuxContainer] = [:]
    private var networks: [String: AppleContainerizationManagedNetwork] = [:]
    private var desiredNetworkAttachments: [String: [RuntimeDesiredNetworkAttachment]] = [:]
    private var observedNetworkAttachments: [String: [RuntimeInventoryNetworkAttachment]] = [:]
    private var policyRecords: [String: ContainerizationHelperPersistedRecord] = [:]
    private var appliedGuestPolicies:
        [String: ContainerizationGuestNetworkPolicy] = [:]
    private var runningPolicyResources = Set<String>()

    init(
        configuration: ContainerizationHelperConfiguration,
        stateStore: ContainerizationHelperStateStore
    ) async throws {
        self.configuration = configuration
        self.stateStore = stateStore

        let imageStoreURL = configuration.dataRootURL.appendingPathComponent("images", isDirectory: true)
        try ContainerizationHelperStateStore.preparePrivateDirectory(imageStoreURL)
        let imageStore = try ImageStore(path: imageStoreURL)
        self.imageStore = imageStore
        if let asset = try ContainerizationGuestPolicyAsset(
            configuration: configuration
        ) {
            guestPolicyStore = try ContainerizationGuestPolicyStore(
                rootURL: configuration.dataRootURL.appendingPathComponent(
                    "guest-network-policies",
                    isDirectory: true
                ),
                asset: asset
            )
        } else {
            guestPolicyStore = nil
        }

        let initImage = try await Self.requireInitImage(
            configuration: configuration,
            imageStore: imageStore
        )
        let bootstrapURL = configuration.dataRootURL.appendingPathComponent("bootstrap", isDirectory: true)
        try ContainerizationHelperStateStore.preparePrivateDirectory(bootstrapURL)
        let initfsURL = bootstrapURL.appendingPathComponent(
            configuration.initfsCacheFileName,
            isDirectory: false
        )
        let initfs: Containerization.Mount
        if FileManager.default.fileExists(atPath: initfsURL.path) {
            _ = try ContainerizationHelperStateStore.requirePrivateRegularFile(initfsURL)
            initfs = .block(
                format: "ext4",
                source: initfsURL.path,
                destination: "/",
                options: ["ro"]
            )
        } else {
            initfs = try await InitImage(image: initImage).initBlock(at: initfsURL, for: .linuxArm)
            guard chmod(initfsURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
        }
        let kernel = Kernel(path: configuration.kernelURL, platform: .linuxArm)
        self.manager = try ContainerManager(
            kernel: kernel,
            initfs: initfs,
            imageStore: imageStore,
            network: nil,
            rosetta: false,
            nestedVirtualization: false
        )
    }

    func resolveProcess(
        for request: ContainerizationHelperCreatePayload
    ) async throws -> ContainerizationHelperResolvedProcess {
        let image = try await imageStore.get(reference: request.image.reference, pull: false)
        let imageConfiguration = try await image.config(for: .current).config
        var process = imageConfiguration.map(LinuxProcessConfiguration.init(from:)) ?? .init()
        if !request.command.isEmpty {
            process.arguments = request.command
        }
        process.environmentVariables = Self.mergedEnvironment(
            base: process.environmentVariables,
            overrides: request.environment
        )
        return ContainerizationHelperResolvedProcess(
            command: process.arguments,
            environment: Self.environmentEntries(process.environmentVariables),
            workingDirectory: process.workingDirectory,
            user: process.user.username.isEmpty ? nil : process.user.username
        )
    }

    func localImageEvidence(reference: String) async throws -> ContainerizationHelperImageEvidence {
        let image = try await imageStore.get(reference: reference, pull: false)
        let variant = try await image.descriptor(for: .current)
        return ContainerizationHelperImageEvidence(
            reference: image.reference,
            descriptorDigest: image.descriptor.digest,
            variantDigest: variant.digest,
            architecture: Platform.current.architecture,
            operatingSystem: Platform.current.os
        )
    }

    func listImages() async throws -> [ContainerizationHelperImageRecord] {
        let images = try await imageStore.list()
        var byDigest: [String: ContainerizationHelperImageRecord] = [:]
        for image in images.sorted(by: { $0.reference < $1.reference }) {
            try Task.checkCancellation()
            guard let variant = try? await image.descriptor(for: .current) else { continue }
            let evidence = ContainerizationHelperImageEvidence(
                reference: image.reference,
                descriptorDigest: image.descriptor.digest,
                variantDigest: variant.digest,
                architecture: Platform.current.architecture,
                operatingSystem: Platform.current.os
            )
            if let current = byDigest[image.descriptor.digest] {
                byDigest[image.descriptor.digest] = ContainerizationHelperImageRecord(
                    evidence: current.evidence,
                    references: (current.references + [image.reference]).sorted()
                )
            } else {
                byDigest[image.descriptor.digest] = ContainerizationHelperImageRecord(
                    evidence: evidence,
                    references: [image.reference]
                )
            }
        }
        return byDigest.values.sorted { $0.evidence.descriptorDigest < $1.evidence.descriptorDigest }
    }

    func listNetworks() async throws -> [ContainerizationHelperRuntimeNetworkRecord] {
        networks.values.map(\.record).sorted {
            $0.identity.runtimeIdentifier < $1.identity.runtimeIdentifier
        }
    }

    func inspectNetwork(
        _ identity: RuntimeNetworkIdentity
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord? {
        guard let managed = networks[identity.runtimeIdentifier],
              managed.record.identity == identity else {
            return nil
        }
        return managed.record
    }

    func createNetwork(
        _ request: RuntimeNetworkCreateRequest,
        labels: [String: String]
    ) async throws -> ContainerizationHelperRuntimeNetworkRecord {
        guard networks[request.identity.runtimeIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("network already exists")
        }
        let mode: vmnet.operating_modes_t
        switch request.mode {
        case .nat:
            mode = .VMNET_SHARED_MODE
        case .hostOnly:
            mode = .VMNET_HOST_MODE
        }
        let subnet: CIDRv4?
        switch request.ipv4 {
        case .automatic:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not expose a qualified automatic IPv4 subnet allocator."
            )
        case .cidr(let value):
            subnet = try CIDRv4(value)
        case .disabled:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork requires IPv4 addressing."
            )
        }
        let prefixV6: CIDRv6?
        switch request.ipv6 {
        case .disabled:
            prefixV6 = nil
        case .cidr(let value):
            prefixV6 = try CIDRv6(value)
        case .automatic:
            throw ContainerizationHelperBackendError.unavailable(
                "Containerization 0.35.0 VmnetNetwork does not allocate an automatic IPv6 prefix."
            )
        }
        let network = try VmnetNetwork(
            mode: mode,
            subnet: subnet,
            prefixV6: prefixV6
        )
        let record = ContainerizationHelperRuntimeNetworkRecord(
            identity: request.identity,
            mode: request.mode,
            ipv4Subnet: network.subnet.description,
            ipv4Gateway: network.ipv4Gateway.description,
            ipv6Prefix: network.prefixV6?.description,
            ipv6Gateway: network.ipv6Gateway?.description,
            labels: labels
        )
        networks[request.identity.runtimeIdentifier] = AppleContainerizationManagedNetwork(
            network: network,
            record: record
        )
        return record
    }

    func deleteNetwork(_ identity: RuntimeNetworkIdentity) async throws {
        guard let managed = networks[identity.runtimeIdentifier],
              managed.record.identity == identity else {
            throw ContainerizationHelperBackendError.rejected("network is not managed")
        }
        let desiredAttachment = desiredNetworkAttachments.values.contains { attachments in
            attachments.contains {
                $0.networkRuntimeIdentifier == identity.runtimeIdentifier
            }
        }
        let allocatedInterface = observedNetworkAttachments.values.contains { attachments in
            attachments.contains {
                $0.networkID == identity.runtimeIdentifier
            }
        }
        guard !desiredAttachment, !allocatedInterface else {
            throw ContainerizationHelperBackendError.conflict(
                "network still has managed container attachments"
            )
        }
        networks.removeValue(forKey: identity.runtimeIdentifier)
    }

    func networkAttachments(
        resourceIdentifier: String
    ) async throws -> [RuntimeInventoryNetworkAttachment] {
        observedNetworkAttachments[resourceIdentifier] ?? []
    }

    func networkPolicyCapabilities()
        async -> RuntimeNetworkPolicyProviderCapabilities {
        guard guestPolicyStore != nil else {
            return .unavailable
        }
        return RuntimeNetworkPolicyProviderCapabilities(
            state: .available,
            reason: .implemented,
            directions: HostwrightNetworkPolicyDirection.allCases,
            enforcesExactIdentity: true,
            enforcesCIDR: true,
            enforcesDNS: true,
            appliesAtomicGenerations: true,
            observesRuleDigest: true
        )
    }

    func reconcileNetworkPolicies(
        records: [ContainerizationHelperPersistedRecord]
    ) async throws -> [String: ContainerizationGuestNetworkPolicyEvidence] {
        let ordered = records.sorted {
            $0.resourceIdentifier < $1.resourceIdentifier
        }
        policyRecords = Dictionary(
            uniqueKeysWithValues: ordered.map {
                ($0.resourceIdentifier, $0)
            }
        )
        let protected = ordered.filter { $0.networkPolicy != nil }
        guard let guestPolicyStore else {
            guard protected.isEmpty else {
                throw ContainerizationHelperBackendError.unavailable(
                    "The verified guest network-policy loader is unavailable."
                )
            }
            return [:]
        }

        var desired: [String: ContainerizationGuestNetworkPolicy] = [:]
        for record in protected {
            desired[record.resourceIdentifier] = try desiredGuestPolicy(
                for: record
            )
        }

        var changed:
            [(String, ContainerizationGuestNetworkPolicy?)] = []
        do {
            for record in protected {
                try Task.checkCancellation()
                guard let policy = desired[record.resourceIdentifier]
                else {
                    throw ContainerizationHelperBackendError.executionFailed(
                        "The compiled guest policy disappeared before enforcement."
                    )
                }
                if runningPolicyResources.contains(
                    record.resourceIdentifier
                ) {
                    let prior = appliedGuestPolicies[
                        record.resourceIdentifier
                    ]
                    try await applyGuestPolicy(
                        policy,
                        to: record.resourceIdentifier,
                        using: guestPolicyStore
                    )
                    if prior != policy {
                        changed.append((record.resourceIdentifier, prior))
                    }
                    appliedGuestPolicies[
                        record.resourceIdentifier
                    ] = policy
                } else {
                    try writeBootstrapPolicy(
                        policy,
                        for: record,
                        using: guestPolicyStore
                    )
                }
            }

            let removed = appliedGuestPolicies.keys
                .filter { desired[$0] == nil }
                .sorted()
            for resourceIdentifier in removed {
                try Task.checkCancellation()
                guard runningPolicyResources.contains(resourceIdentifier),
                      let prior =
                        appliedGuestPolicies[resourceIdentifier] else {
                    appliedGuestPolicies.removeValue(
                        forKey: resourceIdentifier
                    )
                    continue
                }
                try await removeGuestPolicy(
                    prior,
                    from: resourceIdentifier,
                    using: guestPolicyStore
                )
                changed.append((resourceIdentifier, prior))
                appliedGuestPolicies.removeValue(
                    forKey: resourceIdentifier
                )
            }
        } catch {
            await compensateGuestPolicyChanges(
                changed,
                store: guestPolicyStore
            )
            throw error
        }

        return Dictionary(
            uniqueKeysWithValues: protected.map { record in
                let policy = desired[record.resourceIdentifier]!
                return (
                    record.resourceIdentifier,
                    ContainerizationGuestNetworkPolicyEvidence(
                        generation: policy.generation,
                        sha256: policy.sha256,
                        verified: runningPolicyResources.contains(
                            record.resourceIdentifier
                        )
                    )
                )
            }
        )
    }

    func create(
        _ record: ContainerizationHelperPersistedRecord,
        networks: [RuntimeDesiredNetworkAttachment]
    ) async throws {
        guard containers[record.resourceIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict("resource already has a live VM")
        }
        let container = try await makeContainer(
            record,
            useExistingRootfs: false,
            networkAttachments: networks
        )
        do {
            try Task.checkCancellation()
            try await container.create()
            try Task.checkCancellation()
            containers[record.resourceIdentifier] = container
            policyRecords[record.resourceIdentifier] = record
            desiredNetworkAttachments[record.resourceIdentifier] = networks
        } catch {
            try? await container.stop()
            try? releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
            throw error
        }
    }

    func start(_ record: ContainerizationHelperPersistedRecord) async throws {
        let container: LinuxContainer
        if let current = containers[record.resourceIdentifier] {
            container = current
        } else {
            container = try await makeContainer(
                record,
                useExistingRootfs: true,
                networkAttachments: desiredNetworkAttachments[record.resourceIdentifier] ?? []
            )
            try await container.create()
            containers[record.resourceIdentifier] = container
        }
        do {
            try Task.checkCancellation()
            try await container.start()
            try Task.checkCancellation()
            if record.networkPolicy != nil {
                runningPolicyResources.insert(
                    record.resourceIdentifier
                )
            }
        } catch {
            try? await container.stop()
            containers.removeValue(forKey: record.resourceIdentifier)
            runningPolicyResources.remove(record.resourceIdentifier)
            try? releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
            throw error
        }
    }

    func restart(_ record: ContainerizationHelperPersistedRecord) async throws {
        guard let current = containers.removeValue(forKey: record.resourceIdentifier) else {
            throw ContainerizationHelperBackendError.conflict("resource has no live VM")
        }
        runningPolicyResources.remove(record.resourceIdentifier)
        try await current.stop()
        try releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
        try Task.checkCancellation()
        let attachments = desiredNetworkAttachments[record.resourceIdentifier] ?? []
        let replacement = try await makeContainer(
            record,
            useExistingRootfs: true,
            networkAttachments: attachments
        )
        do {
            try await replacement.create()
            try Task.checkCancellation()
            try await replacement.start()
            try Task.checkCancellation()
            containers[record.resourceIdentifier] = replacement
            if record.networkPolicy != nil {
                runningPolicyResources.insert(
                    record.resourceIdentifier
                )
            }
        } catch {
            try? await replacement.stop()
            runningPolicyResources.remove(record.resourceIdentifier)
            try? releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
            throw error
        }
    }

    func stop(_ record: ContainerizationHelperPersistedRecord) async throws {
        guard let container = containers.removeValue(forKey: record.resourceIdentifier) else { return }
        try await container.stop()
        runningPolicyResources.remove(record.resourceIdentifier)
        appliedGuestPolicies.removeValue(
            forKey: record.resourceIdentifier
        )
        try releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
    }

    func delete(_ record: ContainerizationHelperPersistedRecord) async throws {
        if let container = containers.removeValue(forKey: record.resourceIdentifier) {
            try await container.stop()
        }
        runningPolicyResources.remove(record.resourceIdentifier)
        appliedGuestPolicies.removeValue(
            forKey: record.resourceIdentifier
        )
        policyRecords.removeValue(forKey: record.resourceIdentifier)
        try releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
        desiredNetworkAttachments.removeValue(forKey: record.resourceIdentifier)
        var copy = manager
        let root = imageStore.path
            .appendingPathComponent("containers", isDirectory: true)
            .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) {
            try copy.delete(record.resourceIdentifier)
            manager = copy
        }
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw ContainerizationHelperBackendError.executionFailed("managed files remain")
        }
        if let guestPolicyStore {
            try guestPolicyStore.removeShare(
                resourceIdentifier: record.resourceIdentifier
            )
        }
    }

    func usage(resourceIdentifier: String) async throws -> ContainerizationHelperResourceUsage {
        guard let container = containers[resourceIdentifier] else {
            throw ContainerizationHelperBackendError.conflict("resource has no live VM")
        }
        let stats = try await container.statistics()
        return ContainerizationHelperResourceUsage(
            resourceIdentifier: resourceIdentifier,
            cpuUsageMicroseconds: stats.cpu?.usageUsec ?? 0,
            memoryUsageBytes: stats.memory?.usageBytes ?? 0,
            memoryLimitBytes: stats.memory?.limitBytes ?? container.memoryInBytes,
            networkReceiveBytes: Self.saturatingSum(stats.networks?.map(\.receivedBytes) ?? []),
            networkTransmitBytes: Self.saturatingSum(stats.networks?.map(\.transmittedBytes) ?? []),
            blockReadBytes: Self.saturatingSum(stats.blockIO?.devices.map(\.readBytes) ?? []),
            blockWriteBytes: Self.saturatingSum(stats.blockIO?.devices.map(\.writeBytes) ?? []),
            processCount: Int(min(stats.process?.current ?? 0, UInt64(Int.max)))
        )
    }

    func shutdown() async {
        let active = containers.values
        containers.removeAll()
        for container in active {
            try? await container.stop()
        }
        runningPolicyResources.removeAll()
        appliedGuestPolicies.removeAll()
        policyRecords.removeAll()
        for resourceIdentifier in Array(observedNetworkAttachments.keys) {
            try? releaseNetworkInterfaces(resourceIdentifier: resourceIdentifier)
        }
        desiredNetworkAttachments.removeAll()
        networks.removeAll()
    }

    private func makeContainer(
        _ record: ContainerizationHelperPersistedRecord,
        useExistingRootfs: Bool,
        networkAttachments: [RuntimeDesiredNetworkAttachment]
    ) async throws -> LinuxContainer {
        let image = try await imageStore.get(reference: record.image.reference, pull: false)
        let writer = try stateStore.logWriter(resourceIdentifier: record.resourceIdentifier)
        let allocated = try allocateNetworkInterfaces(
            resourceIdentifier: record.resourceIdentifier,
            attachments: networkAttachments
        )
        observedNetworkAttachments[record.resourceIdentifier] =
            allocated.observations
        var preserveAllocations = false
        defer {
            if !preserveAllocations {
                try? releaseNetworkInterfaces(resourceIdentifier: record.resourceIdentifier)
            }
        }
        let guestPolicyShare: URL?
        if record.networkPolicy != nil {
            guard let guestPolicyStore else {
                throw ContainerizationHelperBackendError.unavailable(
                    "The verified guest network-policy loader is unavailable."
                )
            }
            policyRecords[record.resourceIdentifier] = record
            let policy = try desiredGuestPolicy(for: record)
            try writeBootstrapPolicy(
                policy,
                for: record,
                using: guestPolicyStore
            )
            guestPolicyShare = try guestPolicyStore.shareURL(
                resourceIdentifier: record.resourceIdentifier
            )
        } else {
            guestPolicyShare = nil
        }
        var copy = manager
        let container: LinuxContainer
        if useExistingRootfs {
            let rootfsURL = imageStore.path
                .appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
                .appendingPathComponent("rootfs.ext4", isDirectory: false)
            _ = try ContainerizationHelperStateStore.requirePrivateRegularFile(rootfsURL)
            let rootfs = Containerization.Mount.block(
                format: "ext4",
                source: rootfsURL.path,
                destination: "/",
                options: []
            )
            container = try await copy.create(
                record.resourceIdentifier,
                image: image,
                rootfs: rootfs,
                networking: false
            ) { process in
                Self.configure(
                    &process,
                    record: record,
                    writer: writer,
                    guestPolicyShare: guestPolicyShare
                )
                Self.configureNetwork(
                    &process,
                    interfaces: allocated.interfaces
                )
            }
        } else {
            container = try await copy.create(
                record.resourceIdentifier,
                image: image,
                rootfsSizeInBytes: configuration.rootfsSizeBytes,
                networking: false
            ) { process in
                Self.configure(
                    &process,
                    record: record,
                    writer: writer,
                    guestPolicyShare: guestPolicyShare
                )
                Self.configureNetwork(
                    &process,
                    interfaces: allocated.interfaces
                )
            }
            let containerRoot = imageStore.path
                .appendingPathComponent("containers", isDirectory: true)
                .appendingPathComponent(record.resourceIdentifier, isDirectory: true)
            let rootfsURL = containerRoot.appendingPathComponent("rootfs.ext4", isDirectory: false)
            guard chmod(containerRoot.path, S_IRWXU) == 0,
                  chmod(rootfsURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw ContainerizationHelperPersistenceError.operationFailed
            }
        }
        manager = copy
        preserveAllocations = true
        return container
    }

    private func allocateNetworkInterfaces(
        resourceIdentifier: String,
        attachments: [RuntimeDesiredNetworkAttachment]
    ) throws -> (
        interfaces: [any Containerization.Interface],
        observations: [RuntimeInventoryNetworkAttachment]
    ) {
        guard observedNetworkAttachments[resourceIdentifier] == nil else {
            throw ContainerizationHelperBackendError.conflict(
                "container already has allocated network interfaces"
            )
        }
        let ordered = attachments.sorted {
            $0.networkRuntimeIdentifier < $1.networkRuntimeIdentifier
        }
        var interfaces: [any Containerization.Interface] = []
        var observations: [RuntimeInventoryNetworkAttachment] = []
        do {
            for (index, attachment) in ordered.enumerated() {
                guard var managed = networks[attachment.networkRuntimeIdentifier],
                      managed.record.identity.resourceUUID ==
                        attachment.networkResourceUUID else {
                    throw ContainerizationHelperBackendError.rejected(
                        "network attachment ownership changed before container creation"
                    )
                }
                let interface = index == 0
                    ? try managed.network.createInterface(resourceIdentifier)
                    : try managed.network.createInterfaceWithoutGateway(resourceIdentifier)
                guard let interface else {
                    throw ContainerizationHelperBackendError.executionFailed(
                        "Containerization did not allocate the requested network interface"
                    )
                }
                networks[attachment.networkRuntimeIdentifier] = managed
                interfaces.append(interface)
                observations.append(
                    RuntimeInventoryNetworkAttachment(
                        networkID: attachment.networkRuntimeIdentifier,
                        addresses: [interface.ipv4Address.description] +
                            [interface.ipv6Address?.description].compactMap { $0 },
                        gateway: interface.ipv4Gateway?.description ??
                            interface.ipv6Gateway?.description,
                        macAddress: interface.macAddress?.description
                    )
                )
            }
        } catch {
            for attachment in ordered.prefix(interfaces.count) {
                guard var managed = networks[attachment.networkRuntimeIdentifier] else {
                    continue
                }
                try? managed.network.releaseInterface(resourceIdentifier)
                networks[attachment.networkRuntimeIdentifier] = managed
            }
            throw error
        }
        return (interfaces, observations)
    }

    private func releaseNetworkInterfaces(
        resourceIdentifier: String
    ) throws {
        let observations = observedNetworkAttachments[resourceIdentifier] ?? []
        guard observations.allSatisfy({ networks[$0.networkID] != nil }) else {
            throw ContainerizationHelperBackendError.executionFailed(
                "managed network disappeared before interface cleanup"
            )
        }
        for observation in observations {
            guard var managed = networks[observation.networkID] else { continue }
            try managed.network.releaseInterface(resourceIdentifier)
            networks[observation.networkID] = managed
        }
        observedNetworkAttachments.removeValue(forKey: resourceIdentifier)
    }

    private static func configure(
        _ configuration: inout LinuxContainer.Configuration,
        record: ContainerizationHelperPersistedRecord,
        writer: any Writer,
        guestPolicyShare: URL?
    ) {
        configuration.process.environmentVariables = record.environment.map { "\($0.name)=\($0.value)" }
        if let guestPolicyShare {
            configuration.mounts.append(
                .share(
                    source: guestPolicyShare.path,
                    destination:
                        ContainerizationGuestPolicyAsset
                        .guestDirectoryPath,
                    options: ["ro", "nodev", "nosuid"]
                )
            )
            configuration.process.arguments = [
                ContainerizationGuestPolicyAsset.guestLoaderPath,
                "--bootstrap",
                ContainerizationGuestPolicyAsset
                    .guestBootstrapRequestPath,
                "--"
            ] + record.command
            configuration.process.workingDirectory = "/"
            configuration.process.user = User(uid: 0, gid: 0)
            configuration.process.noNewPrivileges = false
            configuration.process.capabilities = LinuxCapabilities(
                capabilities: [
                    .netAdmin,
                    .setgid,
                    .setpcap,
                    .setuid
                ]
            )
        } else {
            configuration.process.arguments = record.command
            configuration.process.workingDirectory =
                record.workingDirectory ?? "/"
            if let user = record.user {
                configuration.process.user = User(username: user)
            }
        }
        configuration.process.stdout = writer
        configuration.process.stderr = writer
    }

    private static func configureNetwork(
        _ configuration: inout LinuxContainer.Configuration,
        interfaces: [any Containerization.Interface]
    ) {
        configuration.interfaces = interfaces
        if let gateway = interfaces.first?.ipv4Gateway {
            configuration.dns = DNS(nameservers: [gateway.description])
        }
    }

    private static func requireInitImage(
        configuration: ContainerizationHelperConfiguration,
        imageStore: ImageStore
    ) async throws -> Containerization.Image {
        var images = try await imageStore.list()
        if !images.contains(where: { $0.reference == configuration.initImageReference }) {
            _ = try await imageStore.load(from: configuration.initImageLayoutURL)
            images = try await imageStore.list()
        }
        guard let image = images.first(where: { $0.reference == configuration.initImageReference }),
              image.descriptor.digest == configuration.initImageDescriptorDigest,
              try await image.descriptor(for: .current).digest == configuration.initImageVariantDigest else {
            throw ContainerizationHelperConfigurationError.assetDigestMismatch
        }
        return image
    }

    private static func mergedEnvironment(
        base: [String],
        overrides: [RuntimeInventoryEnvironmentEntry]
    ) -> [String] {
        var values: [String: String] = [:]
        for entry in base {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                values[String(parts[0])] = String(parts[1])
            }
        }
        for entry in overrides {
            values[entry.name] = entry.value
        }
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }
    }

    private static func environmentEntries(
        _ values: [String]
    ) -> [RuntimeInventoryEnvironmentEntry] {
        values.compactMap { entry in
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return RuntimeInventoryEnvironmentEntry(name: String(parts[0]), value: String(parts[1]))
        }.sorted { $0.name < $1.name }
    }

    private static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { partial, value in
            let (result, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : result
        }
    }
}

enum ContainerizationHelperCapabilitySnapshot {
    static func make() throws -> RuntimeCapabilitySnapshot {
        let helperFingerprint = try executableFingerprint()
        let protocolFingerprint = SHA256.hash(data: Data("hostwright.containerization-helper.protocol.v1".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return RuntimeCapabilitySnapshot(
            descriptor: RuntimeProviderDescriptor(
                providerID: .appleContainerization,
                components: [
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationHelper,
                        version: HostwrightIdentity.version,
                        build: "runtime-provider-v2",
                        fingerprint: helperFingerprint
                    ),
                    RuntimeProviderComponent(
                        identifier: .containerizationHelperProtocolV1,
                        version: RuntimeProviderCapabilityContract.helperProtocolVersion,
                        build: "canonical-json-v1",
                        fingerprint: protocolFingerprint
                    ),
                    RuntimeProviderComponent(
                        identifier: .appleContainerizationFramework,
                        version: ContainerizationHelperConfiguration.frameworkVersion,
                        build: ContainerizationRuntimeAssetContract.frameworkRevision,
                        fingerprint: ContainerizationRuntimeAssetContract.frameworkRevision
                    )
                ],
                minimumMacOSVersion: RuntimeProviderCapabilityContract.minimumMacOSVersion,
                supportedArchitectures: [.arm64]
            ),
            host: RuntimeProviderHostPlatform(
                macOSVersion: RuntimeProviderMacOSVersion(
                    major: version.majorVersion,
                    minor: version.minorVersion,
                    patch: version.patchVersion
                ),
                macOSBuild: operatingSystemBuild(),
                architecture: .arm64
            ),
            features: RuntimeProviderFeature.knownValues.map { feature in
                let implemented: Set<RuntimeProviderFeature> = [
                    .observation,
                    .lifecycle,
                    .processControl,
                    .streaming,
                    .images,
                    .networks,
                    .cancellation,
                    .timeouts,
                    .errors,
                    .cleanup
                ]
                return implemented.contains(feature)
                    ? RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .available,
                        reason: .implemented
                    )
                    : RuntimeProviderFeatureStatus(
                        feature: feature,
                        state: .unavailable,
                        reason: .notImplemented
                    )
            }
        )
    }

    private static func executableFingerprint() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw ContainerizationHelperConfigurationError.unsafeAsset
        }
        let data = try Data(contentsOf: executableURL, options: [.mappedIfSafe])
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func operatingSystemBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
