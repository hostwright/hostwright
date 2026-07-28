import Foundation
import HostwrightCore
import HostwrightNetworking

public enum RuntimeNetworkMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case nat
    case hostOnly
}

public enum RuntimeNetworkAddressMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case disabled
    case cidr
}

public enum RuntimeNetworkAddressRequest: Codable, Equatable, Hashable, Sendable {
    case automatic
    case disabled
    case cidr(String)

    public var mode: RuntimeNetworkAddressMode {
        switch self {
        case .automatic:
            return .automatic
        case .disabled:
            return .disabled
        case .cidr:
            return .cidr
        }
    }

    public var cidr: String? {
        guard case .cidr(let value) = self else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case cidr
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try values.decode(RuntimeNetworkAddressMode.self, forKey: .mode)
        let cidr = try values.decodeIfPresent(String.self, forKey: .cidr)
        switch (mode, cidr) {
        case (.automatic, nil):
            self = .automatic
        case (.disabled, nil):
            self = .disabled
        case (.cidr, .some(let value)):
            self = .cidr(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .cidr,
                in: values,
                debugDescription: "Network address mode and CIDR payload conflict."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(mode, forKey: .mode)
        try values.encodeIfPresent(cidr, forKey: .cidr)
    }
}

public enum RuntimeNetworkProviderOperation: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case create
    case inspect
    case attach
    case detach
    case delete
}

public enum RuntimeNetworkAttachmentTiming: String, Codable, Equatable, Sendable {
    case containerCreateOnly
    case mutable
    case unavailable
}

public struct RuntimeNetworkOperationCapability: Codable, Equatable, Hashable, Sendable {
    public let operation: RuntimeNetworkProviderOperation
    public let state: RuntimeProviderCapabilityState
    public let reason: RuntimeProviderFeatureReason

    public init(
        operation: RuntimeNetworkProviderOperation,
        state: RuntimeProviderCapabilityState,
        reason: RuntimeProviderFeatureReason
    ) {
        self.operation = operation
        self.state = state
        self.reason = reason
    }
}

public struct RuntimeNetworkProviderCapabilities: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let providerID: RuntimeProviderID
    public let operations: [RuntimeNetworkOperationCapability]
    public let modes: [RuntimeNetworkMode]
    public let ipv4AddressModes: [RuntimeNetworkAddressMode]
    public let ipv6AddressModes: [RuntimeNetworkAddressMode]
    public let attachmentTiming: RuntimeNetworkAttachmentTiming

    public init(
        schemaVersion: Int = RuntimeNetworkProviderCapabilities.currentSchemaVersion,
        providerID: RuntimeProviderID,
        operations: [RuntimeNetworkOperationCapability],
        modes: [RuntimeNetworkMode],
        ipv4AddressModes: [RuntimeNetworkAddressMode],
        ipv6AddressModes: [RuntimeNetworkAddressMode],
        attachmentTiming: RuntimeNetworkAttachmentTiming
    ) {
        self.schemaVersion = schemaVersion
        self.providerID = providerID
        self.operations = operations.sorted { $0.operation.rawValue < $1.operation.rawValue }
        self.modes = modes.sorted { $0.rawValue < $1.rawValue }
        self.ipv4AddressModes = ipv4AddressModes.sorted { $0.rawValue < $1.rawValue }
        self.ipv6AddressModes = ipv6AddressModes.sorted { $0.rawValue < $1.rawValue }
        self.attachmentTiming = attachmentTiming
    }

    public func status(
        for operation: RuntimeNetworkProviderOperation
    ) -> RuntimeNetworkOperationCapability? {
        operations.first { $0.operation == operation }
    }

    public static let appleContainerCLI = RuntimeNetworkProviderCapabilities(
        providerID: .appleContainerCLI,
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
        ipv4AddressModes: [.automatic, .cidr],
        ipv6AddressModes: [.disabled],
        attachmentTiming: .containerCreateOnly
    )

    public static let appleContainerizationUnavailable = RuntimeNetworkProviderCapabilities(
        providerID: .appleContainerization,
        operations: RuntimeNetworkProviderOperation.allCases.map {
            RuntimeNetworkOperationCapability(
                operation: $0,
                state: .unavailable,
                reason: .notImplemented
            )
        },
        modes: [],
        ipv4AddressModes: [],
        ipv6AddressModes: [],
        attachmentTiming: .unavailable
    )
}

public enum RuntimeNetworkIdentityError: Error, Equatable, Sendable {
    case invalidLogicalName
    case invalidResourceUUID
    case invalidProjectUUID
    case identityCollision
    case invalidRuntimeIdentifier
    case invalidAliases
}

public struct RuntimeNetworkIdentity: Codable, Equatable, Hashable, Sendable {
    public let logicalName: String
    public let runtimeIdentifier: String
    public let resourceUUID: String
    public let projectUUID: String

    public init(
        logicalName: String,
        projectUUID: String
    ) throws {
        try self.init(
            logicalName: logicalName,
            resourceUUID: HostwrightNetworkIdentity.resourceUUID(
                projectUUID: projectUUID,
                networkName: logicalName
            ),
            projectUUID: projectUUID
        )
    }

    public init(
        logicalName: String,
        resourceUUID: String,
        projectUUID: String,
        runtimeIdentifier: String? = nil
    ) throws {
        guard HostwrightNetworkIdentity.isValidManifestName(logicalName) else {
            throw RuntimeNetworkIdentityError.invalidLogicalName
        }
        guard Self.canonicalUUID(resourceUUID) != nil else {
            throw RuntimeNetworkIdentityError.invalidResourceUUID
        }
        guard Self.canonicalUUID(projectUUID) != nil else {
            throw RuntimeNetworkIdentityError.invalidProjectUUID
        }
        guard resourceUUID != projectUUID else {
            throw RuntimeNetworkIdentityError.identityCollision
        }
        let expectedResourceUUID = HostwrightNetworkIdentity.resourceUUID(
            projectUUID: projectUUID,
            networkName: logicalName
        )
        guard resourceUUID == expectedResourceUUID else {
            throw RuntimeNetworkIdentityError.invalidResourceUUID
        }
        let expected = HostwrightNetworkIdentity.runtimeName(
            projectUUID: projectUUID,
            networkName: logicalName
        )
        guard runtimeIdentifier == nil || runtimeIdentifier == expected else {
            throw RuntimeNetworkIdentityError.invalidRuntimeIdentifier
        }
        self.logicalName = logicalName
        self.runtimeIdentifier = expected
        self.resourceUUID = resourceUUID
        self.projectUUID = projectUUID
    }

    public static func isRuntimeIdentifier(_ value: String) -> Bool {
        value.range(
            of: #"^hw-[a-f0-9]{32}$"#,
            options: .regularExpression
        ) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case logicalName
        case runtimeIdentifier
        case resourceUUID
        case projectUUID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            logicalName: try values.decode(String.self, forKey: .logicalName),
            resourceUUID: try values.decode(String.self, forKey: .resourceUUID),
            projectUUID: try values.decode(String.self, forKey: .projectUUID),
            runtimeIdentifier: try values.decode(String.self, forKey: .runtimeIdentifier)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(logicalName, forKey: .logicalName)
        try values.encode(runtimeIdentifier, forKey: .runtimeIdentifier)
        try values.encode(resourceUUID, forKey: .resourceUUID)
        try values.encode(projectUUID, forKey: .projectUUID)
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            return nil
        }
        return uuid
    }
}

public struct DesiredRuntimeNetwork: Codable, Equatable, Sendable {
    public let identity: RuntimeNetworkIdentity
    public let mode: RuntimeNetworkMode
    public let ipv4: RuntimeNetworkAddressRequest
    public let ipv6: RuntimeNetworkAddressRequest
    public let labels: [String: String]

    public init(
        identity: RuntimeNetworkIdentity,
        mode: RuntimeNetworkMode,
        ipv4: RuntimeNetworkAddressRequest = .automatic,
        ipv6: RuntimeNetworkAddressRequest = .automatic,
        labels: [String: String] = [:]
    ) {
        self.identity = identity
        self.mode = mode
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.labels = labels
    }

    public var createRequest: RuntimeNetworkCreateRequest {
        RuntimeNetworkCreateRequest(
            identity: identity,
            mode: mode,
            ipv4: ipv4,
            ipv6: ipv6,
            labels: labels
        )
    }
}

public struct RuntimeNetworkCreateRequest: Codable, Equatable, Sendable {
    public let identity: RuntimeNetworkIdentity
    public let mode: RuntimeNetworkMode
    public let ipv4: RuntimeNetworkAddressRequest
    public let ipv6: RuntimeNetworkAddressRequest
    public let labels: [String: String]

    public init(
        identity: RuntimeNetworkIdentity,
        mode: RuntimeNetworkMode,
        ipv4: RuntimeNetworkAddressRequest = .automatic,
        ipv6: RuntimeNetworkAddressRequest = .automatic,
        labels: [String: String] = [:]
    ) {
        self.identity = identity
        self.mode = mode
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.labels = labels
    }
}

public struct RuntimeNetworkInspectRequest: Codable, Equatable, Sendable {
    public let identity: RuntimeNetworkIdentity

    public init(identity: RuntimeNetworkIdentity) {
        self.identity = identity
    }
}

public struct RuntimeNetworkDeleteRequest: Codable, Equatable, Sendable {
    public let identity: RuntimeNetworkIdentity
    public let expectedOwnership: RuntimeInventoryOwnershipEvidence?

    public init(
        identity: RuntimeNetworkIdentity,
        expectedOwnership: RuntimeInventoryOwnershipEvidence? = nil
    ) {
        self.identity = identity
        self.expectedOwnership = expectedOwnership
    }
}

public struct RuntimeDesiredNetworkAttachment: Codable, Equatable, Hashable, Sendable {
    public let networkRuntimeIdentifier: String
    public let networkResourceUUID: String
    public let aliases: [String]

    public init(
        network: RuntimeNetworkIdentity,
        aliases: [String] = []
    ) throws {
        let uniqueAliases = Set(aliases)
        guard aliases.count <= HostwrightServiceNetworkAttachment.maximumAliases,
              uniqueAliases.count == aliases.count,
              aliases.allSatisfy(HostwrightNetworkIdentity.isValidManifestName) else {
            throw RuntimeNetworkIdentityError.invalidAliases
        }
        self.networkRuntimeIdentifier = network.runtimeIdentifier
        self.networkResourceUUID = network.resourceUUID
        self.aliases = aliases.sorted()
    }

    public init(
        networkRuntimeIdentifier: String,
        networkResourceUUID: String,
        aliases: [String] = []
    ) throws {
        let sortedAliases = aliases.sorted()
        let expectedRuntimeIdentifier =
            "hw-\(networkResourceUUID.replacingOccurrences(of: "-", with: ""))"
        guard RuntimeNetworkIdentity.isRuntimeIdentifier(networkRuntimeIdentifier),
              let uuid = UUID(uuidString: networkResourceUUID),
              uuid.uuidString.lowercased() == networkResourceUUID,
              networkRuntimeIdentifier == expectedRuntimeIdentifier,
              sortedAliases.count <= HostwrightServiceNetworkAttachment.maximumAliases,
              Set(sortedAliases).count == sortedAliases.count,
              aliases.count == sortedAliases.count,
              aliases.allSatisfy(HostwrightNetworkIdentity.isValidManifestName) else {
            throw RuntimeNetworkIdentityError.invalidResourceUUID
        }
        self.networkRuntimeIdentifier = networkRuntimeIdentifier
        self.networkResourceUUID = networkResourceUUID
        self.aliases = sortedAliases
    }

    private enum CodingKeys: String, CodingKey {
        case networkRuntimeIdentifier
        case networkResourceUUID
        case aliases
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                networkRuntimeIdentifier: values.decode(
                    String.self,
                    forKey: .networkRuntimeIdentifier
                ),
                networkResourceUUID: values.decode(
                    String.self,
                    forKey: .networkResourceUUID
                ),
                aliases: values.decodeIfPresent([String].self, forKey: .aliases) ?? []
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .networkRuntimeIdentifier,
                in: values,
                debugDescription: "Network attachment identity or aliases are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(networkRuntimeIdentifier, forKey: .networkRuntimeIdentifier)
        try values.encode(networkResourceUUID, forKey: .networkResourceUUID)
        if !aliases.isEmpty {
            try values.encode(aliases, forKey: .aliases)
        }
    }
}

public struct RuntimeNetworkAttachmentRequest: Codable, Equatable, Sendable {
    public let attachmentUUID: String
    public let networkRuntimeIdentifier: String
    public let networkResourceUUID: String
    public let containerRuntimeIdentifier: String
    public let containerResourceUUID: String

    public init(
        attachmentUUID: String,
        network: RuntimeNetworkIdentity,
        containerRuntimeIdentifier: String,
        containerResourceUUID: String
    ) throws {
        try self.init(
            attachmentUUID: attachmentUUID,
            networkRuntimeIdentifier: network.runtimeIdentifier,
            networkResourceUUID: network.resourceUUID,
            containerRuntimeIdentifier: containerRuntimeIdentifier,
            containerResourceUUID: containerResourceUUID
        )
    }

    private init(
        attachmentUUID: String,
        networkRuntimeIdentifier: String,
        networkResourceUUID: String,
        containerRuntimeIdentifier: String,
        containerResourceUUID: String
    ) throws {
        guard let attachment = UUID(uuidString: attachmentUUID),
              attachment.uuidString.lowercased() == attachmentUUID,
              let parsedNetworkUUID = UUID(uuidString: networkResourceUUID),
              parsedNetworkUUID.uuidString.lowercased() == networkResourceUUID,
              networkRuntimeIdentifier ==
                "hw-\(networkResourceUUID.replacingOccurrences(of: "-", with: ""))",
              let container = UUID(uuidString: containerResourceUUID),
              container.uuidString.lowercased() == containerResourceUUID,
              attachmentUUID != networkResourceUUID,
              attachmentUUID != containerResourceUUID,
              networkResourceUUID != containerResourceUUID,
              RuntimeManagedResourceIdentity.isCurrentIdentifier(containerRuntimeIdentifier) else {
            throw RuntimeNetworkIdentityError.invalidResourceUUID
        }
        self.attachmentUUID = attachmentUUID
        self.networkRuntimeIdentifier = networkRuntimeIdentifier
        self.networkResourceUUID = networkResourceUUID
        self.containerRuntimeIdentifier = containerRuntimeIdentifier
        self.containerResourceUUID = containerResourceUUID
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentUUID
        case networkRuntimeIdentifier
        case networkResourceUUID
        case containerRuntimeIdentifier
        case containerResourceUUID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                attachmentUUID: try values.decode(String.self, forKey: .attachmentUUID),
                networkRuntimeIdentifier: try values.decode(
                    String.self,
                    forKey: .networkRuntimeIdentifier
                ),
                networkResourceUUID: try values.decode(
                    String.self,
                    forKey: .networkResourceUUID
                ),
                containerRuntimeIdentifier: try values.decode(
                    String.self,
                    forKey: .containerRuntimeIdentifier
                ),
                containerResourceUUID: try values.decode(
                    String.self,
                    forKey: .containerResourceUUID
                )
            )
        } catch let decodingError as DecodingError {
            throw decodingError
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .attachmentUUID,
                in: values,
                debugDescription: "Network attachment ownership identity is invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(attachmentUUID, forKey: .attachmentUUID)
        try values.encode(networkRuntimeIdentifier, forKey: .networkRuntimeIdentifier)
        try values.encode(networkResourceUUID, forKey: .networkResourceUUID)
        try values.encode(containerRuntimeIdentifier, forKey: .containerRuntimeIdentifier)
        try values.encode(containerResourceUUID, forKey: .containerResourceUUID)
    }
}

public enum RuntimeNetworkResultState: String, Codable, Equatable, Sendable {
    case present
    case missing
    case attached
    case detached
}

public struct RuntimeNetworkOperationResult: Codable, Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let operation: RuntimeNetworkProviderOperation
    public let networkRuntimeIdentifier: String
    public let networkResourceUUID: String
    public let attachmentUUID: String?
    public let state: RuntimeNetworkResultState
    public let verified: Bool
    public let observedNetwork: RuntimeInventoryNetwork?

    public init(
        providerID: RuntimeProviderID,
        operation: RuntimeNetworkProviderOperation,
        networkRuntimeIdentifier: String,
        networkResourceUUID: String,
        attachmentUUID: String? = nil,
        state: RuntimeNetworkResultState,
        verified: Bool,
        observedNetwork: RuntimeInventoryNetwork? = nil
    ) {
        self.providerID = providerID
        self.operation = operation
        self.networkRuntimeIdentifier = networkRuntimeIdentifier
        self.networkResourceUUID = networkResourceUUID
        self.attachmentUUID = attachmentUUID
        self.state = state
        self.verified = verified
        self.observedNetwork = observedNetwork
    }
}

public protocol RuntimeNetworkProvider: Sendable {
    func networkCapabilities() async throws -> RuntimeNetworkProviderCapabilities
    func networkInspect(
        _ request: RuntimeNetworkInspectRequest
    ) async throws -> RuntimeNetworkOperationResult
    func networkCreate(
        _ request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult
    func networkAttach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult
    func networkDetach(
        _ request: RuntimeNetworkAttachmentRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult
    func networkDelete(
        _ request: RuntimeNetworkDeleteRequest,
        context: RuntimeMutationContext
    ) async throws -> RuntimeNetworkOperationResult
}

public enum RuntimeNetworkOwnership {
    public static let resourceKindLabel = "dev.hostwright.resource-kind"
    public static let networkNameLabel = "dev.hostwright.network"
    public static let resourceKind = "network"

    public static func labels(
        for identity: RuntimeNetworkIdentity,
        context: RuntimeMutationContext,
        userLabels: [String: String] = [:]
    ) throws -> [String: String] {
        guard context.validationIssue == nil,
              context.resourceUUID == identity.resourceUUID,
              context.projectResourceUUID == identity.projectUUID else {
            throw RuntimeManagedResourceIdentityError.invalidMutationContext
        }
        guard userLabels.count <= RuntimeInventoryLimits.maximumLabelsPerResource,
              userLabels.allSatisfy({
                  !$0.key.hasPrefix("dev.hostwright.") &&
                      !$0.key.isEmpty &&
                      !$0.key.contains("=") &&
                      $0.key.utf8.count <= 128 &&
                      $0.value.utf8.count <= RuntimeInventoryLimits.maximumStringBytes &&
                      $0.key.rangeOfCharacter(from: .controlCharacters) == nil &&
                      $0.value.rangeOfCharacter(from: .controlCharacters) == nil
              }) else {
            throw RuntimeManagedResourceIdentityError.invalidMutationContext
        }
        var labels = userLabels
        labels[RuntimeManagedResourceIdentity.managedLabel] = "true"
        labels[RuntimeManagedResourceIdentity.identityVersionLabel] =
            String(RuntimeManagedResourceIdentity.currentVersion)
        labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] =
            identity.runtimeIdentifier
        labels[RuntimeManagedResourceIdentity.resourceUUIDLabel] =
            identity.resourceUUID
        labels[RuntimeManagedResourceIdentity.projectUUIDLabel] =
            identity.projectUUID
        labels[RuntimeManagedResourceIdentity.resourceGenerationLabel] =
            String(context.resourceGeneration)
        labels[RuntimeManagedResourceIdentity.projectGenerationLabel] =
            String(context.projectGeneration)
        labels[RuntimeManagedResourceIdentity.providerIDLabel] =
            context.providerID.rawValue
        labels[RuntimeManagedResourceIdentity.providerGenerationLabel] =
            String(context.providerGeneration)
        labels[RuntimeManagedResourceIdentity.fencingTokenLabel] =
            context.fencingToken
        labels[resourceKindLabel] = resourceKind
        labels[networkNameLabel] = identity.logicalName
        return labels
    }

    public static func verify(
        _ network: AppleContainerNetworkEvidence,
        request: RuntimeNetworkCreateRequest,
        context: RuntimeMutationContext
    ) throws -> RuntimeInventoryOwnershipEvidence {
        guard network.id == request.identity.runtimeIdentifier,
              network.name == request.identity.runtimeIdentifier,
              network.mode.rawValue == request.mode.rawValue,
              network.labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] ==
                request.identity.runtimeIdentifier,
              network.labels[resourceKindLabel] == resourceKind,
              network.labels[networkNameLabel] == request.identity.logicalName else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container network observation did not match the requested Hostwright network identity."
            )
        }
        let ownership = try RuntimeManagedResourceIdentity.ownershipEvidence(
            from: network.labels,
            expectedProviderID: context.providerID
        )
        guard let ownership,
              ownership.resourceUUID == request.identity.resourceUUID,
              ownership.projectUUID == request.identity.projectUUID,
              ownership.resourceGeneration == context.resourceGeneration,
              ownership.projectGeneration == context.projectGeneration,
              ownership.providerGeneration == context.providerGeneration,
              ownership.fencingToken == context.fencingToken else {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container network observation did not preserve exact UUID ownership and fencing evidence."
            )
        }
        try verifyAddress(request.ipv4, observed: network.ipv4Subnet, family: "IPv4")
        try verifyAddress(request.ipv6, observed: network.ipv6Subnet, family: "IPv6")
        return ownership
    }

    private static func verifyAddress(
        _ request: RuntimeNetworkAddressRequest,
        observed: String?,
        family: String
    ) throws {
        switch request {
        case .automatic:
            guard observed?.isEmpty == false else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container network observation omitted the requested automatic \(family) allocation."
                )
            }
        case .disabled:
            guard observed == nil else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container network observation assigned disabled \(family) addressing."
                )
            }
        case .cidr(let expected):
            guard observed == expected else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container network observation did not match the requested \(family) CIDR."
                )
            }
        }
    }
}
