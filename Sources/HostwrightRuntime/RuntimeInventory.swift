import CryptoKit
import Foundation

public enum RuntimeInventoryLimits {
    public static let maximumContainers = 512
    public static let maximumImages = 1_024
    public static let maximumNetworks = 256
    public static let maximumVolumes = 256
    public static let maximumLabelsPerResource = 128
    public static let maximumPortsPerContainer = 128
    public static let maximumMountsPerContainer = 128
    public static let maximumNetworksPerContainer = 64
    public static let maximumServicesPerRecord = 128
    public static let maximumArgumentsPerContainer = 256
    public static let maximumEnvironmentEntriesPerContainer = 256
    public static let maximumReferencesPerImage = 128
    public static let maximumVariantsPerImage = 64
    public static let maximumAddressesPerNetwork = 64
    public static let maximumStringBytes = 4_096
}

public enum RuntimeInventoryError: Error, Equatable, Sendable {
    case limitExceeded
    case malformedRecord
    case duplicateIdentity
    case conflictingLabel
    case invalidOwnershipEvidence
    case duplicateOwnershipUUID
    case invalidHealth
    case invalidMachineState
    case encodingFailed
}

public struct RuntimeInventoryLabel: Codable, Equatable, Hashable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct RuntimeInventoryOwnershipEvidence: Codable, Equatable, Hashable, Sendable {
    public let resourceUUID: String
    public let projectUUID: String
    public let resourceGeneration: Int
    public let projectGeneration: Int
    public let providerID: RuntimeProviderID
    public let providerGeneration: Int
    public let fencingToken: String

    public init(
        resourceUUID: String,
        projectUUID: String,
        resourceGeneration: Int,
        projectGeneration: Int,
        providerID: RuntimeProviderID,
        providerGeneration: Int,
        fencingToken: String
    ) {
        self.resourceUUID = resourceUUID
        self.projectUUID = projectUUID
        self.resourceGeneration = resourceGeneration
        self.projectGeneration = projectGeneration
        self.providerID = providerID
        self.providerGeneration = providerGeneration
        self.fencingToken = fencingToken
    }
}

public enum RuntimeInventoryLifecycleState: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case missing
    case created
    case running
    case stopped
    case exited
    case failed
}

public enum RuntimeInventoryHealthAvailability: String, Codable, Equatable, Hashable, Sendable {
    case available
    case notConfigured = "not-configured"
    case unsupported
    case unavailable
}

public enum RuntimeInventoryHealthState: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case starting
    case healthy
    case unhealthy
}

public struct RuntimeInventoryHealth: Codable, Equatable, Hashable, Sendable {
    public let availability: RuntimeInventoryHealthAvailability
    public let state: RuntimeInventoryHealthState?

    public init(
        availability: RuntimeInventoryHealthAvailability,
        state: RuntimeInventoryHealthState? = nil
    ) {
        self.availability = availability
        self.state = state
    }
}

public enum RuntimeInventoryServiceState: String, Codable, Equatable, Hashable, Sendable {
    case running
    case stopped
    case unavailable
    case failed
    case unknown
}

public struct RuntimeInventoryService: Codable, Equatable, Hashable, Sendable {
    public let identifier: String
    public let state: RuntimeInventoryServiceState
    public let required: Bool

    public init(identifier: String, state: RuntimeInventoryServiceState, required: Bool) {
        self.identifier = identifier
        self.state = state
        self.required = required
    }
}

public enum RuntimeInventoryMachineState: String, Codable, Equatable, Hashable, Sendable {
    case running
    case stopped
    case degraded
    case unavailable
    case unknown
}

public struct RuntimeInventoryMachine: Codable, Equatable, Hashable, Sendable {
    public let state: RuntimeInventoryMachineState
    public let operatingSystem: String
    public let architecture: String
    public let runtimeVersion: String
    public let services: [RuntimeInventoryService]

    public init(
        state: RuntimeInventoryMachineState,
        operatingSystem: String,
        architecture: String,
        runtimeVersion: String,
        services: [RuntimeInventoryService]
    ) {
        self.state = state
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.runtimeVersion = runtimeVersion
        self.services = services
    }
}

public struct RuntimeInventoryEnvironmentEntry: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct RuntimeInventoryInitConfiguration: Codable, Equatable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [RuntimeInventoryEnvironmentEntry]
    public let workingDirectory: String?
    public let user: String?
    public let terminal: Bool

    public init(
        executable: String,
        arguments: [String],
        environment: [RuntimeInventoryEnvironmentEntry],
        workingDirectory: String? = nil,
        user: String? = nil,
        terminal: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.user = user
        self.terminal = terminal
    }
}

public enum RuntimeInventoryPortProtocol: String, Codable, Equatable, Hashable, Sendable {
    case tcp
    case udp
}

public struct RuntimeInventoryPort: Codable, Equatable, Hashable, Sendable {
    public let hostAddress: String?
    public let hostPort: Int?
    public let containerPort: Int
    public let protocolName: RuntimeInventoryPortProtocol

    public init(
        hostAddress: String? = nil,
        hostPort: Int? = nil,
        containerPort: Int,
        protocolName: RuntimeInventoryPortProtocol
    ) {
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.protocolName = protocolName
    }
}

public enum RuntimeInventoryMountKind: String, Codable, Equatable, Hashable, Sendable {
    case bind
    case volume
    case tmpfs
}

public enum RuntimeInventoryMountAccess: String, Codable, Equatable, Hashable, Sendable {
    case readOnly = "read-only"
    case readWrite = "read-write"
}

public struct RuntimeInventoryMount: Codable, Equatable, Hashable, Sendable {
    public let source: String
    public let target: String
    public let kind: RuntimeInventoryMountKind
    public let access: RuntimeInventoryMountAccess

    public init(
        source: String,
        target: String,
        kind: RuntimeInventoryMountKind,
        access: RuntimeInventoryMountAccess
    ) {
        self.source = source
        self.target = target
        self.kind = kind
        self.access = access
    }
}

public struct RuntimeInventoryNetworkAttachment: Codable, Equatable, Hashable, Sendable {
    public let networkID: String
    public let interfaceName: String?
    public let addresses: [String]
    public let gateway: String?
    public let macAddress: String?

    public init(
        networkID: String,
        interfaceName: String? = nil,
        addresses: [String],
        gateway: String? = nil,
        macAddress: String? = nil
    ) {
        self.networkID = networkID
        self.interfaceName = interfaceName
        self.addresses = addresses
        self.gateway = gateway
        self.macAddress = macAddress
    }
}

public struct RuntimeInventoryAllocation: Codable, Equatable, Hashable, Sendable {
    public let cpuCount: Int?
    public let memoryBytes: UInt64?
    public let storageBytes: UInt64?

    public init(cpuCount: Int? = nil, memoryBytes: UInt64? = nil, storageBytes: UInt64? = nil) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
    }
}

public struct RuntimeInventoryUsage: Codable, Equatable, Hashable, Sendable {
    public let cpuUsageMicroseconds: UInt64
    public let memoryUsageBytes: UInt64
    public let memoryLimitBytes: UInt64
    public let networkReceiveBytes: UInt64
    public let networkTransmitBytes: UInt64
    public let blockReadBytes: UInt64
    public let blockWriteBytes: UInt64
    public let processCount: Int

    public init(
        cpuUsageMicroseconds: UInt64,
        memoryUsageBytes: UInt64,
        memoryLimitBytes: UInt64,
        networkReceiveBytes: UInt64,
        networkTransmitBytes: UInt64,
        blockReadBytes: UInt64,
        blockWriteBytes: UInt64,
        processCount: Int
    ) {
        self.cpuUsageMicroseconds = cpuUsageMicroseconds
        self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes
        self.networkReceiveBytes = networkReceiveBytes
        self.networkTransmitBytes = networkTransmitBytes
        self.blockReadBytes = blockReadBytes
        self.blockWriteBytes = blockWriteBytes
        self.processCount = processCount
    }
}

public struct RuntimeInventoryContainer: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let name: String
    public let imageID: String?
    public let imageReference: String
    public let lifecycle: RuntimeInventoryLifecycleState
    public let health: RuntimeInventoryHealth
    public let labels: [RuntimeInventoryLabel]
    public let ownership: RuntimeInventoryOwnershipEvidence?
    public let initConfiguration: RuntimeInventoryInitConfiguration
    public let ports: [RuntimeInventoryPort]
    public let mounts: [RuntimeInventoryMount]
    public let networks: [RuntimeInventoryNetworkAttachment]
    public let allocation: RuntimeInventoryAllocation?
    public let usage: RuntimeInventoryUsage?
    public let services: [RuntimeInventoryService]

    public init(
        runtimeID: String,
        name: String,
        imageID: String? = nil,
        imageReference: String,
        lifecycle: RuntimeInventoryLifecycleState,
        health: RuntimeInventoryHealth,
        labels: [RuntimeInventoryLabel],
        ownership: RuntimeInventoryOwnershipEvidence? = nil,
        initConfiguration: RuntimeInventoryInitConfiguration,
        ports: [RuntimeInventoryPort],
        mounts: [RuntimeInventoryMount],
        networks: [RuntimeInventoryNetworkAttachment],
        allocation: RuntimeInventoryAllocation? = nil,
        usage: RuntimeInventoryUsage? = nil,
        services: [RuntimeInventoryService]
    ) {
        self.runtimeID = runtimeID
        self.name = name
        self.imageID = imageID
        self.imageReference = imageReference
        self.lifecycle = lifecycle
        self.health = health
        self.labels = labels
        self.ownership = ownership
        self.initConfiguration = initConfiguration
        self.ports = ports
        self.mounts = mounts
        self.networks = networks
        self.allocation = allocation
        self.usage = usage
        self.services = services
    }
}

public struct RuntimeInventoryImageVariant: Codable, Equatable, Hashable, Sendable {
    public let digest: String
    public let architecture: String
    public let operatingSystem: String

    public init(digest: String, architecture: String, operatingSystem: String) {
        self.digest = digest
        self.architecture = architecture
        self.operatingSystem = operatingSystem
    }
}

public struct RuntimeInventoryImage: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let descriptorDigest: String
    public let references: [String]
    public let variants: [RuntimeInventoryImageVariant]
    public let labels: [RuntimeInventoryLabel]
    public let ownership: RuntimeInventoryOwnershipEvidence?

    public init(
        runtimeID: String,
        descriptorDigest: String,
        references: [String],
        variants: [RuntimeInventoryImageVariant],
        labels: [RuntimeInventoryLabel],
        ownership: RuntimeInventoryOwnershipEvidence? = nil
    ) {
        self.runtimeID = runtimeID
        self.descriptorDigest = descriptorDigest
        self.references = references
        self.variants = variants
        self.labels = labels
        self.ownership = ownership
    }
}

public struct RuntimeInventoryNetwork: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let name: String
    public let kind: String
    public let addresses: [String]
    public let labels: [RuntimeInventoryLabel]
    public let ownership: RuntimeInventoryOwnershipEvidence?

    public init(
        runtimeID: String,
        name: String,
        kind: String,
        addresses: [String],
        labels: [RuntimeInventoryLabel],
        ownership: RuntimeInventoryOwnershipEvidence? = nil
    ) {
        self.runtimeID = runtimeID
        self.name = name
        self.kind = kind
        self.addresses = addresses
        self.labels = labels
        self.ownership = ownership
    }
}

public struct RuntimeInventoryVolume: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: String
    public let name: String
    public let mountPoint: String?
    public let capacityBytes: UInt64?
    public let usedBytes: UInt64?
    public let labels: [RuntimeInventoryLabel]
    public let ownership: RuntimeInventoryOwnershipEvidence?

    public init(
        runtimeID: String,
        name: String,
        mountPoint: String? = nil,
        capacityBytes: UInt64? = nil,
        usedBytes: UInt64? = nil,
        labels: [RuntimeInventoryLabel],
        ownership: RuntimeInventoryOwnershipEvidence? = nil
    ) {
        self.runtimeID = runtimeID
        self.name = name
        self.mountPoint = mountPoint
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
        self.labels = labels
        self.ownership = ownership
    }
}

public struct RuntimeInventory: Equatable, Sendable {
    public let machine: RuntimeInventoryMachine
    public let containers: [RuntimeInventoryContainer]
    public let images: [RuntimeInventoryImage]
    public let networks: [RuntimeInventoryNetwork]
    public let volumes: [RuntimeInventoryVolume]
    public let semanticSHA256: String

    fileprivate init(
        machine: RuntimeInventoryMachine,
        containers: [RuntimeInventoryContainer],
        images: [RuntimeInventoryImage],
        networks: [RuntimeInventoryNetwork],
        volumes: [RuntimeInventoryVolume],
        semanticSHA256: String
    ) {
        self.machine = machine
        self.containers = containers
        self.images = images
        self.networks = networks
        self.volumes = volumes
        self.semanticSHA256 = semanticSHA256
    }
}

public enum RuntimeInventoryBuilder {
    public static func build(
        machine: RuntimeInventoryMachine,
        containers: [RuntimeInventoryContainer],
        images: [RuntimeInventoryImage],
        networks: [RuntimeInventoryNetwork],
        volumes: [RuntimeInventoryVolume],
        redactionPolicy: RuntimeRedactionPolicy = .default,
        cancellationCheck: () throws -> Void = {
            if Task<Never, Never>.isCancelled {
                throw CancellationError()
            }
        }
    ) throws -> RuntimeInventory {
        try cancellationCheck()
        guard containers.count <= RuntimeInventoryLimits.maximumContainers,
              images.count <= RuntimeInventoryLimits.maximumImages,
              networks.count <= RuntimeInventoryLimits.maximumNetworks,
              volumes.count <= RuntimeInventoryLimits.maximumVolumes else {
            throw RuntimeInventoryError.limitExceeded
        }

        let normalized = try normalizeInventory(
            machine: machine,
            containers: containers,
            images: images,
            networks: networks,
            volumes: volumes,
            redactionPolicy: redactionPolicy,
            cancellationCheck: cancellationCheck
        )
        let semantic = redactionPolicy == .default
            ? normalized
            : try normalizeInventory(
                machine: machine,
                containers: containers,
                images: images,
                networks: networks,
                volumes: volumes,
                redactionPolicy: .default,
                cancellationCheck: cancellationCheck
            )

        try cancellationCheck()
        let payload = RuntimeInventorySemanticPayload(
            machine: semantic.machine,
            containers: semantic.containers.map(excludingVolatileUsage),
            images: semantic.images,
            networks: semantic.networks,
            volumes: semantic.volumes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            throw RuntimeInventoryError.encodingFailed
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return RuntimeInventory(
            machine: normalized.machine,
            containers: normalized.containers,
            images: normalized.images,
            networks: normalized.networks,
            volumes: normalized.volumes,
            semanticSHA256: digest
        )
    }

    private static func excludingVolatileUsage(
        _ container: RuntimeInventoryContainer
    ) -> RuntimeInventoryContainer {
        RuntimeInventoryContainer(
            runtimeID: container.runtimeID,
            name: container.name,
            imageID: container.imageID,
            imageReference: container.imageReference,
            lifecycle: container.lifecycle,
            health: container.health,
            labels: container.labels,
            ownership: container.ownership,
            initConfiguration: container.initConfiguration,
            ports: container.ports,
            mounts: container.mounts,
            networks: container.networks,
            allocation: container.allocation,
            usage: nil,
            services: container.services
        )
    }

    private static func normalizeInventory(
        machine: RuntimeInventoryMachine,
        containers: [RuntimeInventoryContainer],
        images: [RuntimeInventoryImage],
        networks: [RuntimeInventoryNetwork],
        volumes: [RuntimeInventoryVolume],
        redactionPolicy: RuntimeRedactionPolicy,
        cancellationCheck: () throws -> Void
    ) throws -> RuntimeInventoryNormalizedParts {
        try cancellationCheck()
        let normalizedMachine = try normalize(machine, redactionPolicy: redactionPolicy)
        let normalizedContainers = try containers.map { container in
            try cancellationCheck()
            return try normalize(container, redactionPolicy: redactionPolicy)
        }.sorted { $0.runtimeID < $1.runtimeID }
        let normalizedImages = try images.map { image in
            try cancellationCheck()
            return try normalize(image, redactionPolicy: redactionPolicy)
        }.sorted { $0.runtimeID < $1.runtimeID }
        let normalizedNetworks = try networks.map { network in
            try cancellationCheck()
            return try normalize(network, redactionPolicy: redactionPolicy)
        }.sorted { $0.runtimeID < $1.runtimeID }
        let normalizedVolumes = try volumes.map { volume in
            try cancellationCheck()
            return try normalize(volume, redactionPolicy: redactionPolicy)
        }.sorted { $0.runtimeID < $1.runtimeID }

        try requireUnique(normalizedContainers.map(\.runtimeID))
        try requireUnique(normalizedImages.map(\.runtimeID))
        try requireUnique(normalizedNetworks.map(\.runtimeID))
        try requireUnique(normalizedVolumes.map(\.runtimeID))

        let ownershipUUIDs = normalizedContainers.compactMap(\.ownership?.resourceUUID) +
            normalizedImages.compactMap(\.ownership?.resourceUUID) +
            normalizedNetworks.compactMap(\.ownership?.resourceUUID) +
            normalizedVolumes.compactMap(\.ownership?.resourceUUID)
        guard Set(ownershipUUIDs).count == ownershipUUIDs.count else {
            throw RuntimeInventoryError.duplicateOwnershipUUID
        }

        return RuntimeInventoryNormalizedParts(
            machine: normalizedMachine,
            containers: normalizedContainers,
            images: normalizedImages,
            networks: normalizedNetworks,
            volumes: normalizedVolumes
        )
    }

    private static func normalize(
        _ machine: RuntimeInventoryMachine,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryMachine {
        let services = try normalizeServices(machine.services, redactionPolicy: redactionPolicy)
        let requiredServiceLost = services.contains { $0.required && $0.state != .running }
        let serviceIsRunning = services.contains { $0.state == .running }
        if machine.state == .running && requiredServiceLost {
            throw RuntimeInventoryError.invalidMachineState
        }
        if (machine.state == .stopped || machine.state == .unavailable) && serviceIsRunning {
            throw RuntimeInventoryError.invalidMachineState
        }
        return RuntimeInventoryMachine(
            state: machine.state,
            operatingSystem: try text(machine.operatingSystem, redactionPolicy: redactionPolicy),
            architecture: try text(machine.architecture, redactionPolicy: redactionPolicy),
            runtimeVersion: try text(machine.runtimeVersion, redactionPolicy: redactionPolicy),
            services: services
        )
    }

    private static func normalize(
        _ container: RuntimeInventoryContainer,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryContainer {
        guard container.labels.count <= RuntimeInventoryLimits.maximumLabelsPerResource,
              container.ports.count <= RuntimeInventoryLimits.maximumPortsPerContainer,
              container.mounts.count <= RuntimeInventoryLimits.maximumMountsPerContainer,
              container.networks.count <= RuntimeInventoryLimits.maximumNetworksPerContainer,
              container.services.count <= RuntimeInventoryLimits.maximumServicesPerRecord else {
            throw RuntimeInventoryError.limitExceeded
        }
        let ownership = try normalize(container.ownership)
        let labels = try normalizeLabels(
            container.labels,
            ownership: ownership,
            redactionPolicy: redactionPolicy
        )
        let ports = try container.ports.map { try normalize($0, redactionPolicy: redactionPolicy) }
            .sorted(by: portOrder)
        try requireUnique(ports)
        let mounts = try container.mounts.map { try normalize($0, redactionPolicy: redactionPolicy) }
            .sorted { $0.target < $1.target }
        try requireUnique(mounts.map(\.target))
        let attachments = try container.networks.map {
            try normalize($0, redactionPolicy: redactionPolicy)
        }.sorted { $0.networkID < $1.networkID }
        try requireUnique(attachments.map(\.networkID))
        let health = try normalize(container.health)
        let allocation = try normalize(container.allocation)
        let usage = try normalize(container.usage)
        return RuntimeInventoryContainer(
            runtimeID: try text(container.runtimeID, redactionPolicy: redactionPolicy),
            name: try text(container.name, redactionPolicy: redactionPolicy),
            imageID: try optionalText(container.imageID, redactionPolicy: redactionPolicy),
            imageReference: try text(container.imageReference, redactionPolicy: redactionPolicy),
            lifecycle: container.lifecycle,
            health: health,
            labels: labels,
            ownership: ownership,
            initConfiguration: try normalize(
                container.initConfiguration,
                redactionPolicy: redactionPolicy
            ),
            ports: ports,
            mounts: mounts,
            networks: attachments,
            allocation: allocation,
            usage: usage,
            services: try normalizeServices(container.services, redactionPolicy: redactionPolicy)
        )
    }

    private static func normalize(
        _ image: RuntimeInventoryImage,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryImage {
        guard image.labels.count <= RuntimeInventoryLimits.maximumLabelsPerResource,
              !image.references.isEmpty,
              image.references.count <= RuntimeInventoryLimits.maximumReferencesPerImage,
              image.variants.count <= RuntimeInventoryLimits.maximumVariantsPerImage,
              validDigest(image.descriptorDigest) else {
            throw image.references.count > RuntimeInventoryLimits.maximumReferencesPerImage ||
                image.variants.count > RuntimeInventoryLimits.maximumVariantsPerImage ||
                image.labels.count > RuntimeInventoryLimits.maximumLabelsPerResource
                ? RuntimeInventoryError.limitExceeded
                : RuntimeInventoryError.malformedRecord
        }
        let ownership = try normalize(image.ownership)
        let references = try image.references.map {
            try text($0, redactionPolicy: redactionPolicy)
        }.sorted()
        try requireUnique(references)
        let variants = try image.variants.map { variant in
            guard validDigest(variant.digest) else {
                throw RuntimeInventoryError.malformedRecord
            }
            return RuntimeInventoryImageVariant(
                digest: variant.digest,
                architecture: try text(variant.architecture, redactionPolicy: redactionPolicy),
                operatingSystem: try text(variant.operatingSystem, redactionPolicy: redactionPolicy)
            )
        }.sorted {
            ($0.architecture, $0.operatingSystem, $0.digest) <
                ($1.architecture, $1.operatingSystem, $1.digest)
        }
        try requireUnique(variants)
        return RuntimeInventoryImage(
            runtimeID: try text(image.runtimeID, redactionPolicy: redactionPolicy),
            descriptorDigest: image.descriptorDigest,
            references: references,
            variants: variants,
            labels: try normalizeLabels(
                image.labels,
                ownership: ownership,
                redactionPolicy: redactionPolicy
            ),
            ownership: ownership
        )
    }

    private static func normalize(
        _ network: RuntimeInventoryNetwork,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryNetwork {
        guard network.labels.count <= RuntimeInventoryLimits.maximumLabelsPerResource,
              network.addresses.count <= RuntimeInventoryLimits.maximumAddressesPerNetwork else {
            throw RuntimeInventoryError.limitExceeded
        }
        let ownership = try normalize(network.ownership)
        let addresses = try network.addresses.map {
            try text($0, redactionPolicy: redactionPolicy)
        }.sorted()
        try requireUnique(addresses)
        return RuntimeInventoryNetwork(
            runtimeID: try text(network.runtimeID, redactionPolicy: redactionPolicy),
            name: try text(network.name, redactionPolicy: redactionPolicy),
            kind: try text(network.kind, redactionPolicy: redactionPolicy),
            addresses: addresses,
            labels: try normalizeLabels(
                network.labels,
                ownership: ownership,
                redactionPolicy: redactionPolicy
            ),
            ownership: ownership
        )
    }

    private static func normalize(
        _ volume: RuntimeInventoryVolume,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryVolume {
        guard volume.labels.count <= RuntimeInventoryLimits.maximumLabelsPerResource,
              volume.capacityBytes == nil || volume.usedBytes == nil || volume.usedBytes! <= volume.capacityBytes! else {
            throw volume.labels.count > RuntimeInventoryLimits.maximumLabelsPerResource
                ? RuntimeInventoryError.limitExceeded
                : RuntimeInventoryError.malformedRecord
        }
        let ownership = try normalize(volume.ownership)
        return RuntimeInventoryVolume(
            runtimeID: try text(volume.runtimeID, redactionPolicy: redactionPolicy),
            name: try text(volume.name, redactionPolicy: redactionPolicy),
            mountPoint: try optionalText(volume.mountPoint, redactionPolicy: redactionPolicy),
            capacityBytes: volume.capacityBytes,
            usedBytes: volume.usedBytes,
            labels: try normalizeLabels(
                volume.labels,
                ownership: ownership,
                redactionPolicy: redactionPolicy
            ),
            ownership: ownership
        )
    }

    private static func normalize(
        _ configuration: RuntimeInventoryInitConfiguration,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryInitConfiguration {
        guard configuration.arguments.count <= RuntimeInventoryLimits.maximumArgumentsPerContainer,
              configuration.environment.count <= RuntimeInventoryLimits.maximumEnvironmentEntriesPerContainer else {
            throw RuntimeInventoryError.limitExceeded
        }
        let environment = try configuration.environment.map { entry in
            let name = try text(entry.name, redactionPolicy: redactionPolicy)
            let value = try boundedText(entry.value, allowEmpty: true)
            let redactedValue = redactionPolicy.isSensitiveKey(name)
                ? redactionPolicy.replacement
                : redactionPolicy.redact(value)
            return RuntimeInventoryEnvironmentEntry(
                name: name,
                value: try boundedText(redactedValue, allowEmpty: true)
            )
        }.sorted { $0.name < $1.name }
        try requireUnique(environment.map(\.name))
        return RuntimeInventoryInitConfiguration(
            executable: try text(configuration.executable, redactionPolicy: redactionPolicy),
            arguments: try configuration.arguments.map {
                let value = try boundedText($0, allowEmpty: true)
                return try boundedText(redactionPolicy.redact(value), allowEmpty: true)
            },
            environment: environment,
            workingDirectory: try optionalText(
                configuration.workingDirectory,
                redactionPolicy: redactionPolicy
            ),
            user: try optionalText(configuration.user, redactionPolicy: redactionPolicy),
            terminal: configuration.terminal
        )
    }

    private static func normalize(
        _ port: RuntimeInventoryPort,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryPort {
        guard (1...65_535).contains(port.containerPort),
              port.hostPort == nil || (1...65_535).contains(port.hostPort!) else {
            throw RuntimeInventoryError.malformedRecord
        }
        return RuntimeInventoryPort(
            hostAddress: try optionalText(port.hostAddress, redactionPolicy: redactionPolicy),
            hostPort: port.hostPort,
            containerPort: port.containerPort,
            protocolName: port.protocolName
        )
    }

    private static func normalize(
        _ mount: RuntimeInventoryMount,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryMount {
        RuntimeInventoryMount(
            source: try text(mount.source, redactionPolicy: redactionPolicy),
            target: try text(mount.target, redactionPolicy: redactionPolicy),
            kind: mount.kind,
            access: mount.access
        )
    }

    private static func normalize(
        _ attachment: RuntimeInventoryNetworkAttachment,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> RuntimeInventoryNetworkAttachment {
        guard attachment.addresses.count <= RuntimeInventoryLimits.maximumAddressesPerNetwork else {
            throw RuntimeInventoryError.limitExceeded
        }
        let addresses = try attachment.addresses.map {
            try text($0, redactionPolicy: redactionPolicy)
        }.sorted()
        try requireUnique(addresses)
        return RuntimeInventoryNetworkAttachment(
            networkID: try text(attachment.networkID, redactionPolicy: redactionPolicy),
            interfaceName: try optionalText(attachment.interfaceName, redactionPolicy: redactionPolicy),
            addresses: addresses,
            gateway: try optionalText(attachment.gateway, redactionPolicy: redactionPolicy),
            macAddress: try optionalText(attachment.macAddress, redactionPolicy: redactionPolicy)
        )
    }

    private static func normalize(_ health: RuntimeInventoryHealth) throws -> RuntimeInventoryHealth {
        switch health.availability {
        case .available:
            guard health.state != nil else { throw RuntimeInventoryError.invalidHealth }
        case .notConfigured, .unsupported, .unavailable:
            guard health.state == nil else { throw RuntimeInventoryError.invalidHealth }
        }
        return health
    }

    private static func normalize(
        _ allocation: RuntimeInventoryAllocation?
    ) throws -> RuntimeInventoryAllocation? {
        guard let allocation else { return nil }
        guard allocation.cpuCount != nil || allocation.memoryBytes != nil || allocation.storageBytes != nil,
              allocation.cpuCount == nil || allocation.cpuCount! > 0,
              allocation.memoryBytes == nil || allocation.memoryBytes! > 0,
              allocation.storageBytes == nil || allocation.storageBytes! > 0 else {
            throw RuntimeInventoryError.malformedRecord
        }
        return allocation
    }

    private static func normalize(_ usage: RuntimeInventoryUsage?) throws -> RuntimeInventoryUsage? {
        guard let usage else { return nil }
        guard usage.processCount >= 0 else { throw RuntimeInventoryError.malformedRecord }
        return usage
    }

    private static func normalize(
        _ ownership: RuntimeInventoryOwnershipEvidence?
    ) throws -> RuntimeInventoryOwnershipEvidence? {
        guard let ownership else { return nil }
        guard let resourceUUID = UUID(uuidString: ownership.resourceUUID),
              let projectUUID = UUID(uuidString: ownership.projectUUID),
              let fencingToken = UUID(uuidString: ownership.fencingToken),
              resourceUUID != projectUUID,
              RuntimeProviderID.knownValues.contains(ownership.providerID),
              ownership.resourceGeneration > 0,
              ownership.projectGeneration > 0,
              ownership.providerGeneration > 0 else {
            throw RuntimeInventoryError.invalidOwnershipEvidence
        }
        return RuntimeInventoryOwnershipEvidence(
            resourceUUID: resourceUUID.uuidString.lowercased(),
            projectUUID: projectUUID.uuidString.lowercased(),
            resourceGeneration: ownership.resourceGeneration,
            projectGeneration: ownership.projectGeneration,
            providerID: ownership.providerID,
            providerGeneration: ownership.providerGeneration,
            fencingToken: fencingToken.uuidString.lowercased()
        )
    }

    private static func normalizeLabels(
        _ labels: [RuntimeInventoryLabel],
        ownership: RuntimeInventoryOwnershipEvidence?,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> [RuntimeInventoryLabel] {
        var rawByKey: [String: String] = [:]
        var normalized: [RuntimeInventoryLabel] = []
        for label in labels {
            let rawKey = try boundedText(label.key, allowEmpty: false)
            let value = try boundedText(label.value, allowEmpty: true)
            guard rawByKey[rawKey] == nil else {
                throw RuntimeInventoryError.conflictingLabel
            }
            rawByKey[rawKey] = value
            let key = try boundedText(redactionPolicy.redact(rawKey), allowEmpty: false)
            let redactedValue = redactionPolicy.isSensitiveKey(rawKey)
                ? redactionPolicy.replacement
                : redactionPolicy.redact(value)
            normalized.append(
                RuntimeInventoryLabel(
                    key: key,
                    value: try boundedText(redactedValue, allowEmpty: true)
                )
            )
        }
        let managed = rawByKey[RuntimeManagedResourceIdentity.managedLabel]
        if managed == "true", ownership == nil {
            throw RuntimeInventoryError.invalidOwnershipEvidence
        }
        if ownership != nil {
            guard let managed else {
                throw RuntimeInventoryError.invalidOwnershipEvidence
            }
            guard managed == "true" else {
                throw RuntimeInventoryError.conflictingLabel
            }
        }
        guard Set(normalized.map(\.key)).count == normalized.count else {
            throw RuntimeInventoryError.conflictingLabel
        }
        return normalized.sorted {
            ($0.key, $0.value) < ($1.key, $1.value)
        }
    }

    private static func normalizeServices(
        _ services: [RuntimeInventoryService],
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> [RuntimeInventoryService] {
        guard services.count <= RuntimeInventoryLimits.maximumServicesPerRecord else {
            throw RuntimeInventoryError.limitExceeded
        }
        let normalized = try services.map {
            RuntimeInventoryService(
                identifier: try text($0.identifier, redactionPolicy: redactionPolicy),
                state: $0.state,
                required: $0.required
            )
        }.sorted { $0.identifier < $1.identifier }
        try requireUnique(normalized.map(\.identifier))
        return normalized
    }

    private static func text(
        _ value: String,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> String {
        let bounded = try boundedText(value, allowEmpty: false)
        return try boundedText(redactionPolicy.redact(bounded), allowEmpty: false)
    }

    private static func optionalText(
        _ value: String?,
        redactionPolicy: RuntimeRedactionPolicy
    ) throws -> String? {
        guard let value else { return nil }
        return try text(value, redactionPolicy: redactionPolicy)
    }

    private static func boundedText(_ value: String, allowEmpty: Bool) throws -> String {
        guard allowEmpty || !value.isEmpty,
              value.utf8.count <= RuntimeInventoryLimits.maximumStringBytes,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw RuntimeInventoryError.malformedRecord
        }
        return value
    }

    private static func validDigest(_ value: String) -> Bool {
        value.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    private static func requireUnique<T: Hashable>(_ values: [T]) throws {
        guard Set(values).count == values.count else {
            throw RuntimeInventoryError.duplicateIdentity
        }
    }

    private static func portOrder(_ lhs: RuntimeInventoryPort, _ rhs: RuntimeInventoryPort) -> Bool {
        (
            lhs.containerPort,
            lhs.hostAddress ?? "",
            lhs.hostPort ?? 0,
            lhs.protocolName.rawValue
        ) < (
            rhs.containerPort,
            rhs.hostAddress ?? "",
            rhs.hostPort ?? 0,
            rhs.protocolName.rawValue
        )
    }
}

private struct RuntimeInventoryNormalizedParts {
    let machine: RuntimeInventoryMachine
    let containers: [RuntimeInventoryContainer]
    let images: [RuntimeInventoryImage]
    let networks: [RuntimeInventoryNetwork]
    let volumes: [RuntimeInventoryVolume]
}

private struct RuntimeInventorySemanticPayload: Codable {
    let machine: RuntimeInventoryMachine
    let containers: [RuntimeInventoryContainer]
    let images: [RuntimeInventoryImage]
    let networks: [RuntimeInventoryNetwork]
    let volumes: [RuntimeInventoryVolume]
}
