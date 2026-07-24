import Foundation

public struct AppleContainerInventoryOutputs: Sendable {
    public let version: String
    public let systemStatus: String
    public let containers: String
    public let images: String
    public let networks: String
    public let volumes: String
    public let machines: String
    public let statsByContainerID: [String: String]

    public init(
        version: String,
        systemStatus: String,
        containers: String,
        images: String,
        networks: String,
        volumes: String,
        machines: String,
        statsByContainerID: [String: String] = [:]
    ) {
        self.version = version
        self.systemStatus = systemStatus
        self.containers = containers
        self.images = images
        self.networks = networks
        self.volumes = volumes
        self.machines = machines
        self.statsByContainerID = statsByContainerID
    }
}

public enum AppleContainerInventoryDetailAvailability: String, Equatable, Sendable {
    case unsupported
}

public enum AppleContainerInventoryParser {
    public static let maximumContainerBytes = AppleContainerObservationParser.maximumBytes
    public static let maximumImageBytes = AppleContainerImageListOutputParser.maximumBytes
    public static let maximumStatsBytes = AppleContainerStatsParser.maximumBytes
    public static let maximumCombinedStatsBytes = 16 * 1_024 * 1_024
    public static let healthDetailsAvailability = RuntimeInventoryHealthAvailability.unsupported
    public static let processDetailsAvailability = AppleContainerInventoryDetailAvailability.unsupported

    public static func parse(
        outputs: AppleContainerInventoryOutputs,
        redactionPolicy: RuntimeRedactionPolicy = .default,
        cancellationCheck: () throws -> Void = {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
        }
    ) throws -> RuntimeInventory {
        do {
            try cancellationCheck()
            let codec = try AppleContainerCLICodec.select(
                fromVersionOutput: outputs.version,
                redactionPolicy: redactionPolicy
            )
            let readiness = try codec.decodeSystemStatus(
                outputs.systemStatus,
                versionOutput: outputs.version,
                redactionPolicy: redactionPolicy
            )

            try cancellationCheck()
            let containerPayloads = try decodeContainers(outputs.containers)
            let imagePayloads = try decodeImages(outputs.images)
            let networkEvidence = try codec.decodeNetworks(
                outputs.networks,
                redactionPolicy: redactionPolicy
            )
            let volumeEvidence = try codec.decodeVolumes(
                outputs.volumes,
                redactionPolicy: redactionPolicy
            )
            let machineEvidence = try codec.decodeMachines(
                outputs.machines,
                redactionPolicy: redactionPolicy
            )

            try cancellationCheck()
            let usages = try decodeStats(
                outputs.statsByContainerID,
                observedContainerIDs: Set(containerPayloads.map(\.id)),
                cancellationCheck: cancellationCheck
            )
            let containers = try containerPayloads.map { payload in
                try cancellationCheck()
                return try mapContainer(payload, usage: usages[payload.id])
            }
            let images = try mapImages(imagePayloads, cancellationCheck: cancellationCheck)
            let networks = try networkEvidence.map { evidence in
                try cancellationCheck()
                return try mapNetwork(evidence)
            }
            let volumes = try volumeEvidence.map { evidence in
                try cancellationCheck()
                return try mapVolume(evidence)
            }
            let machine = try mapMachine(
                readiness: readiness,
                machines: machineEvidence
            )

            try cancellationCheck()
            return try RuntimeInventoryBuilder.build(
                machine: machine,
                containers: containers,
                images: images,
                networks: networks,
                volumes: volumes,
                redactionPolicy: redactionPolicy,
                cancellationCheck: cancellationCheck
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory output was incomplete, conflicting, or malformed."
            )
        }
    }

    private static func decodeContainers(_ text: String) throws -> [ContainerPayload] {
        let data = try AppleContainerStructuredOutput.validatedJSONData(
            text,
            operation: "Apple container inventory container list",
            maximumBytes: maximumContainerBytes
        )
        let payloads = try decoder.decode([ContainerPayload].self, from: data)
        guard payloads.count <= RuntimeInventoryLimits.maximumContainers else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory exceeded the container count limit."
            )
        }
        return payloads
    }

    private static func decodeImages(_ text: String) throws -> [ImagePayload] {
        let data = try AppleContainerStructuredOutput.validatedJSONData(
            text,
            operation: "Apple container inventory image list",
            maximumBytes: maximumImageBytes
        )
        let payloads = try decoder.decode([ImagePayload].self, from: data)
        guard payloads.count <= RuntimeInventoryLimits.maximumImages else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory exceeded the image count limit."
            )
        }
        return payloads
    }

    private static func decodeStats(
        _ outputs: [String: String],
        observedContainerIDs: Set<String>,
        cancellationCheck: () throws -> Void
    ) throws -> [String: RuntimeInventoryUsage] {
        guard outputs.count <= RuntimeInventoryLimits.maximumContainers,
              outputs.keys.allSatisfy(observedContainerIDs.contains),
              outputs.reduce(0, { partial, item in
                  let (sum, overflow) = partial.addingReportingOverflow(item.value.utf8.count)
                  return overflow ? Int.max : sum
              }) <= maximumCombinedStatsBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory stats were oversized or referenced an unknown container."
            )
        }

        var result: [String: RuntimeInventoryUsage] = [:]
        for containerID in outputs.keys.sorted() {
            try cancellationCheck()
            guard let output = outputs[containerID] else { continue }
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                output,
                operation: "Apple container inventory stats",
                maximumBytes: maximumStatsBytes
            )
            let payloads = try decoder.decode([StatsPayload].self, from: data)
            guard payloads.count == 1,
                  let payload = payloads.first,
                  payload.id == containerID,
                  payload.numProcesses <= UInt64(Int.max) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory stats did not identify exactly one observed container."
                )
            }
            result[containerID] = RuntimeInventoryUsage(
                cpuUsageMicroseconds: payload.cpuUsageUsec,
                memoryUsageBytes: payload.memoryUsageBytes,
                memoryLimitBytes: payload.memoryLimitBytes,
                networkReceiveBytes: payload.networkRxBytes,
                networkTransmitBytes: payload.networkTxBytes,
                blockReadBytes: payload.blockReadBytes,
                blockWriteBytes: payload.blockWriteBytes,
                processCount: Int(payload.numProcesses)
            )
        }
        return result
    }

    private static func mapContainer(
        _ payload: ContainerPayload,
        usage: RuntimeInventoryUsage?
    ) throws -> RuntimeInventoryContainer {
        guard payload.id == payload.configuration.id,
              validDigest(payload.configuration.image.descriptor.digest),
              validSemanticText(payload.configuration.platform.architecture),
              validSemanticText(payload.configuration.platform.os),
              payload.configuration.platform.variant.map(validSemanticText) ?? true,
              payload.status.startedDate.map(validSemanticText) ?? true,
              payload.configuration.resources.cpuOverhead >= 0 else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory contained conflicting or malformed container evidence."
            )
        }
        let lifecycle = lifecycle(payload.status)
        return RuntimeInventoryContainer(
            runtimeID: payload.id,
            name: payload.configuration.id,
            imageID: payload.configuration.image.descriptor.digest,
            imageReference: payload.configuration.image.reference,
            lifecycle: lifecycle,
            health: RuntimeInventoryHealth(availability: healthDetailsAvailability),
            labels: inventoryLabels(payload.configuration.labels),
            ownership: try ownership(
                labels: payload.configuration.labels,
                resourceIdentifier: payload.id
            ),
            initConfiguration: try initConfiguration(payload.configuration.initProcess),
            ports: try ports(payload.configuration.publishedPorts),
            mounts: try mounts(payload.configuration.mounts),
            networks: try networkAttachments(
                configured: payload.configuration.networks,
                observed: payload.status.networks
            ),
            allocation: RuntimeInventoryAllocation(
                cpuCount: payload.configuration.resources.cpus,
                memoryBytes: payload.configuration.resources.memoryInBytes,
                storageBytes: payload.configuration.resources.storage
            ),
            usage: usage,
            services: [
                RuntimeInventoryService(
                    identifier: "init",
                    state: serviceState(lifecycle),
                    required: true
                )
            ]
        )
    }

    private static func mapImages(
        _ payloads: [ImagePayload],
        cancellationCheck: () throws -> Void
    ) throws -> [RuntimeInventoryImage] {
        var accumulated: [String: ImageAccumulator] = [:]
        for payload in payloads {
            try cancellationCheck()
            let digest = payload.configuration.descriptor.digest
            guard digest.hasPrefix("sha256:"),
                  String(digest.dropFirst("sha256:".count)) == payload.id else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained conflicting image identities."
                )
            }
            let variants = payload.variants.map {
                RuntimeInventoryImageVariant(
                    digest: $0.digest,
                    architecture: $0.platform.architecture,
                    operatingSystem: $0.platform.os
                )
            }.sorted {
                ($0.architecture, $0.operatingSystem, $0.digest) <
                    ($1.architecture, $1.operatingSystem, $1.digest)
            }
            guard Set(variants).count == variants.count else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained duplicate image variants."
                )
            }
            let rawLabels = payload.configuration.descriptor.annotations ?? [:]
            let labels = inventoryLabels(rawLabels)
            let imageOwnership = try ownership(
                labels: rawLabels,
                resourceIdentifier: payload.id
            )

            if var existing = accumulated[payload.id] {
                guard existing.descriptorDigest == digest,
                      existing.variants == variants,
                      existing.labels == labels,
                      existing.ownership == imageOwnership,
                      !existing.references.contains(payload.configuration.name) else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container inventory contained conflicting duplicate image evidence."
                    )
                }
                existing.references.append(payload.configuration.name)
                accumulated[payload.id] = existing
            } else {
                accumulated[payload.id] = ImageAccumulator(
                    descriptorDigest: digest,
                    references: [payload.configuration.name],
                    variants: variants,
                    labels: labels,
                    ownership: imageOwnership
                )
            }
        }
        return accumulated.map { id, image in
            RuntimeInventoryImage(
                runtimeID: id,
                descriptorDigest: image.descriptorDigest,
                references: image.references,
                variants: image.variants,
                labels: image.labels,
                ownership: image.ownership
            )
        }
    }

    private static func mapNetwork(
        _ evidence: AppleContainerNetworkEvidence
    ) throws -> RuntimeInventoryNetwork {
        let addresses = [evidence.ipv4Subnet, evidence.ipv4Gateway] +
            [evidence.ipv6Subnet].compactMap { $0 }
        return RuntimeInventoryNetwork(
            runtimeID: evidence.id,
            name: evidence.name,
            kind: "\(evidence.plugin):\(evidence.mode.rawValue)",
            addresses: addresses,
            labels: inventoryLabels(evidence.labels),
            ownership: try ownership(
                labels: evidence.labels,
                resourceIdentifier: evidence.id
            )
        )
    }

    private static func mapVolume(
        _ evidence: AppleContainerVolumeEvidence
    ) throws -> RuntimeInventoryVolume {
        RuntimeInventoryVolume(
            runtimeID: evidence.id,
            name: evidence.name,
            mountPoint: evidence.source,
            capacityBytes: evidence.sizeInBytes,
            usedBytes: nil,
            labels: inventoryLabels(evidence.labels),
            ownership: try ownership(
                labels: evidence.labels,
                resourceIdentifier: evidence.id
            )
        )
    }

    private static func mapMachine(
        readiness: RuntimeReadinessReport,
        machines: [AppleContainerMachineEvidence]
    ) throws -> RuntimeInventoryMachine {
        let apiState: RuntimeInventoryServiceState
        switch readiness.serviceState {
        case .running:
            apiState = .running
        case .notRunning:
            apiState = .stopped
        case .unregistered:
            apiState = .unavailable
        }

        var services = [
            RuntimeInventoryService(
                identifier: "container-apiserver",
                state: apiState,
                required: true
            )
        ]
        services += machines.map { machine in
            RuntimeInventoryService(
                identifier: "machine:\(machine.id)",
                state: machineServiceState(machine.status),
                required: machine.isDefault
            )
        }

        let requiredLost = services.contains { $0.required && $0.state != .running }
        let anyRunning = services.contains { $0.state == .running }
        let state: RuntimeInventoryMachineState
        if !requiredLost {
            state = .running
        } else if anyRunning {
            state = .degraded
        } else {
            switch readiness.serviceState {
            case .running:
                state = .degraded
            case .notRunning:
                state = .stopped
            case .unregistered:
                state = .unavailable
            }
        }

        return RuntimeInventoryMachine(
            state: state,
            operatingSystem: "linux",
            architecture: "arm64",
            runtimeVersion: readiness.cliVersion,
            services: services
        )
    }

    private static func initConfiguration(
        _ process: ProcessPayload
    ) throws -> RuntimeInventoryInitConfiguration {
        guard process.supplementalGroups.isEmpty, process.rlimits.isEmpty else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory process group or rlimit details are unsupported."
            )
        }
        var seenNames = Set<String>()
        let environment = try process.environment.map { entry in
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained a malformed environment entry."
                )
            }
            let name = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard seenNames.insert(name).inserted else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained a duplicate environment name."
                )
            }
            return RuntimeInventoryEnvironmentEntry(name: name, value: value)
        }
        return RuntimeInventoryInitConfiguration(
            executable: process.executable,
            arguments: process.arguments,
            environment: environment,
            workingDirectory: process.workingDirectory,
            user: process.user.description,
            terminal: process.terminal
        )
    }

    private static func ports(_ payloads: [PortPayload]) throws -> [RuntimeInventoryPort] {
        var result: [RuntimeInventoryPort] = []
        for payload in payloads {
            guard payload.count > 0,
                  payload.hostPort > 0,
                  payload.containerPort > 0,
                  payload.hostPort <= 65_535,
                  payload.containerPort <= 65_535,
                  payload.count <= 65_535,
                  payload.hostPort <= 65_535 - (payload.count - 1),
                  payload.containerPort <= 65_535 - (payload.count - 1),
                  result.count <= RuntimeInventoryLimits.maximumPortsPerContainer - payload.count else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained an invalid published port range."
                )
            }
            for offset in 0..<payload.count {
                result.append(
                    RuntimeInventoryPort(
                        hostAddress: payload.hostAddress,
                        hostPort: payload.hostPort + offset,
                        containerPort: payload.containerPort + offset,
                        protocolName: payload.proto
                    )
                )
            }
        }
        return result
    }

    private static func mounts(_ payloads: [MountPayload]) throws -> [RuntimeInventoryMount] {
        try payloads.map { payload in
            let hasReadOnly = payload.options.contains("ro")
            let hasReadWrite = payload.options.contains("rw")
            guard !(hasReadOnly && hasReadWrite),
                  payload.options.allSatisfy({ $0 == "ro" || $0 == "rw" }) else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained unsupported or conflicting mount options."
                )
            }
            let access: RuntimeInventoryMountAccess = hasReadOnly ? .readOnly : .readWrite
            switch payload.type {
            case .bind:
                return RuntimeInventoryMount(
                    source: payload.source,
                    target: payload.destination,
                    kind: .bind,
                    access: access
                )
            case .volume(let details):
                guard validSemanticText(details.name),
                      validSemanticText(details.format),
                      validSemanticText(details.cache),
                      validSemanticText(details.sync) else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container inventory contained malformed volume mount details."
                    )
                }
                return RuntimeInventoryMount(
                    source: payload.source,
                    target: payload.destination,
                    kind: .volume,
                    access: access
                )
            case .tmpfs:
                return RuntimeInventoryMount(
                    source: "tmpfs",
                    target: payload.destination,
                    kind: .tmpfs,
                    access: access
                )
            case .block:
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory block mounts are unsupported."
                )
            }
        }
    }

    private static func networkAttachments(
        configured: [ConfiguredNetworkPayload],
        observed: [ObservedNetworkPayload]
    ) throws -> [RuntimeInventoryNetworkAttachment] {
        let configuredByID = Dictionary(grouping: configured, by: \.network)
        let observedByID = Dictionary(grouping: observed, by: \.network)
        guard configuredByID.values.allSatisfy({ $0.count == 1 }),
              observedByID.values.allSatisfy({ $0.count == 1 }),
              Set(observedByID.keys).isSubset(of: Set(configuredByID.keys)) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory contained duplicate or conflicting network attachments."
            )
        }

        return try configured.map { configuredNetwork in
            guard let configuredItem = configuredByID[configuredNetwork.network]?.first else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory omitted a configured network identity."
                )
            }
            guard let observedItem = observedByID[configuredNetwork.network]?.first else {
                return RuntimeInventoryNetworkAttachment(
                    networkID: configuredItem.network,
                    addresses: [],
                    gateway: nil,
                    macAddress: configuredItem.options.macAddress
                )
            }
            guard observedItem.hostname == configuredItem.options.hostname,
                  configuredItem.options.macAddress == nil ||
                    configuredItem.options.macAddress == observedItem.macAddress,
                  configuredItem.options.mtu == nil ||
                    configuredItem.options.mtu == observedItem.mtu else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container inventory contained conflicting network attachment details."
                )
            }
            return RuntimeInventoryNetworkAttachment(
                networkID: observedItem.network,
                addresses: [observedItem.ipv4Address] +
                    [observedItem.ipv6Address].compactMap { $0 },
                gateway: observedItem.ipv4Gateway,
                macAddress: observedItem.macAddress ?? configuredItem.options.macAddress
            )
        }
    }

    private static func ownership(
        labels: [String: String],
        resourceIdentifier: String
    ) throws -> RuntimeInventoryOwnershipEvidence? {
        let evidence = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: labels,
            expectedProviderID: .appleContainerCLI
        )
        guard evidence != nil else { return nil }
        guard let identity = RuntimeManagedResourceIdentity.identity(from: labels),
              RuntimeManagedResourceIdentity.labelsMatch(
                labels,
                identity: identity,
                resourceIdentifier: resourceIdentifier
              ) else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container inventory contained conflicting managed identity labels."
            )
        }
        return evidence
    }

    private static func inventoryLabels(
        _ labels: [String: String]
    ) -> [RuntimeInventoryLabel] {
        labels.map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
            .sorted { ($0.key, $0.value) < ($1.key, $1.value) }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func validSemanticText(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= RuntimeInventoryLimits.maximumStringBytes &&
            value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func lifecycle(
        _ status: ContainerStatusPayload
    ) -> RuntimeInventoryLifecycleState {
        switch status.state {
        case .running:
            return .running
        case .stopped:
            return status.startedDate == nil ? .stopped : .exited
        case .unknown, .stopping:
            return .unknown
        }
    }

    private static func serviceState(
        _ lifecycle: RuntimeInventoryLifecycleState
    ) -> RuntimeInventoryServiceState {
        switch lifecycle {
        case .running:
            return .running
        case .stopped, .exited:
            return .stopped
        case .failed:
            return .failed
        case .unknown, .missing, .created:
            return .unknown
        }
    }

    private static func machineServiceState(
        _ status: AppleContainerMachineStatus
    ) -> RuntimeInventoryServiceState {
        switch status {
        case .running:
            return .running
        case .stopped:
            return .stopped
        case .unknown, .stopping:
            return .unknown
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct ContainerPayload: Decodable {
    let id: String
    let configuration: ContainerConfigurationPayload
    let status: ContainerStatusPayload
}

private struct ContainerConfigurationPayload: Decodable {
    let id: String
    let image: ImageDescriptionPayload
    let mounts: [MountPayload]
    let publishedPorts: [PortPayload]
    let labels: [String: String]
    let networks: [ConfiguredNetworkPayload]
    let initProcess: ProcessPayload
    let platform: PlatformPayload
    let resources: ResourcesPayload
}

private struct ImageDescriptionPayload: Decodable {
    let reference: String
    let descriptor: DescriptorPayload
}

private struct DescriptorPayload: Decodable {
    let digest: String
    let annotations: [String: String]?
}

private struct ProcessPayload: Decodable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let workingDirectory: String
    let terminal: Bool
    let user: ProcessUserPayload
    let supplementalGroups: [UInt32]
    let rlimits: [ProcessRlimitPayload]
}

private struct ProcessRlimitPayload: Decodable {
    let limit: String
    let soft: UInt64
    let hard: UInt64
}

private enum ProcessUserPayload: Decodable {
    case raw(String)
    case id(uid: UInt32, gid: UInt32)

    var description: String {
        switch self {
        case .raw(let value):
            return value
        case .id(let uid, let gid):
            return "\(uid):\(gid)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "ambiguous process user")
            )
        }
        switch key.stringValue {
        case "raw":
            self = .raw(try container.decode(RawUserPayload.self, forKey: key).userString)
        case "id":
            let value = try container.decode(IDUserPayload.self, forKey: key)
            self = .id(uid: value.uid, gid: value.gid)
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported process user")
            )
        }
    }
}

private struct RawUserPayload: Decodable {
    let userString: String
}

private struct IDUserPayload: Decodable {
    let uid: UInt32
    let gid: UInt32
}

private struct PortPayload: Decodable {
    let hostAddress: String
    let hostPort: Int
    let containerPort: Int
    let proto: RuntimeInventoryPortProtocol
    let count: Int
}

private struct MountPayload: Decodable {
    let type: MountTypePayload
    let source: String
    let destination: String
    let options: [String]
}

private enum MountTypePayload: Decodable {
    case bind
    case volume(VolumeMountPayload)
    case tmpfs
    case block

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "ambiguous mount type")
            )
        }
        switch key.stringValue {
        case "virtiofs":
            _ = try container.decode(IgnoredObjectPayload.self, forKey: key)
            self = .bind
        case "volume":
            self = .volume(try container.decode(VolumeMountPayload.self, forKey: key))
        case "tmpfs":
            _ = try container.decode(IgnoredObjectPayload.self, forKey: key)
            self = .tmpfs
        case "block":
            _ = try container.decode(IgnoredObjectPayload.self, forKey: key)
            self = .block
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "unsupported mount type")
            )
        }
    }
}

private struct IgnoredObjectPayload: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: DynamicCodingKey.self)
    }
}

private struct VolumeMountPayload: Decodable {
    let name: String
    let format: String
    let cache: String
    let sync: String
}

private struct ConfiguredNetworkPayload: Decodable {
    let network: String
    let options: ConfiguredNetworkOptionsPayload
}

private struct ConfiguredNetworkOptionsPayload: Decodable {
    let hostname: String
    let macAddress: String?
    let mtu: Int?
}

private struct ResourcesPayload: Decodable {
    let cpus: Int
    let memoryInBytes: UInt64
    let storage: UInt64?
    let cpuOverhead: Int
}

private struct PlatformPayload: Decodable {
    let architecture: String
    let os: String
    let variant: String?
}

private struct ContainerStatusPayload: Decodable {
    let state: AppleContainerMachineStatus
    let networks: [ObservedNetworkPayload]
    let startedDate: String?
}

private struct ObservedNetworkPayload: Decodable {
    let network: String
    let hostname: String
    let ipv4Address: String
    let ipv4Gateway: String
    let ipv6Address: String?
    let macAddress: String?
    let mtu: Int?
}

private struct ImagePayload: Decodable {
    let id: String
    let configuration: ImageConfigurationPayload
    let variants: [ImageVariantPayload]
}

private struct ImageConfigurationPayload: Decodable {
    let name: String
    let descriptor: DescriptorPayload
}

private struct ImageVariantPayload: Decodable {
    let digest: String
    let platform: PlatformPayload
}

private struct StatsPayload: Decodable {
    let id: String
    let cpuUsageUsec: UInt64
    let memoryUsageBytes: UInt64
    let memoryLimitBytes: UInt64
    let networkRxBytes: UInt64
    let networkTxBytes: UInt64
    let blockReadBytes: UInt64
    let blockWriteBytes: UInt64
    let numProcesses: UInt64
}

private struct ImageAccumulator {
    let descriptorDigest: String
    var references: [String]
    let variants: [RuntimeInventoryImageVariant]
    let labels: [RuntimeInventoryLabel]
    let ownership: RuntimeInventoryOwnershipEvidence?
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
