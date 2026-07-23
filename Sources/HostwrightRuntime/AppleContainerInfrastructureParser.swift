import Foundation

public enum AppleContainerNetworkMode: String, Codable, Equatable, Sendable {
    case nat
    case hostOnly
}

public struct AppleContainerNetworkEvidence: Equatable, Sendable {
    public let id: String
    public let name: String
    public let mode: AppleContainerNetworkMode
    public let creationDate: Date
    public let plugin: String
    public let labels: [String: String]
    public let options: [String: String]
    public let ipv4Subnet: String
    public let ipv4Gateway: String
    public let ipv6Subnet: String?
}

public struct AppleContainerVolumeEvidence: Equatable, Sendable {
    public let id: String
    public let name: String
    public let driver: String
    public let format: String
    public let source: String
    public let creationDate: Date
    public let labels: [String: String]
    public let options: [String: String]
    public let sizeInBytes: UInt64?
}

public enum AppleContainerMachineStatus: String, Codable, Equatable, Sendable {
    case unknown
    case stopped
    case running
    case stopping
}

public struct AppleContainerMachineEvidence: Equatable, Sendable {
    public let id: String
    public let status: AppleContainerMachineStatus
    public let isDefault: Bool
    public let ipAddress: String?
    public let cpuCount: Int
    public let memoryBytes: UInt64
    public let diskSizeBytes: UInt64?
    public let creationDate: Date?
}

public enum AppleContainerNetworkListParser {
    public static let maximumBytes = 1 * 1_024 * 1_024
    public static let maximumEntries = 256
    public static let maximumStringBytes = 4_096
    public static let maximumMetadataEntries = 128

    public static func parse(
        _ text: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerNetworkEvidence] {
        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                text,
                operation: "Apple container network list",
                maximumBytes: maximumBytes
            )
            let payloads = try AppleContainerInfrastructureDecoding.decoder.decode(
                [NetworkPayload].self,
                from: data
            )
            guard payloads.count <= maximumEntries else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container network list exceeded the \(maximumEntries)-entry codec limit."
                )
            }

            var seenIdentifiers = Set<String>()
            return try payloads.map { payload in
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.id,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.name,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )
                guard payload.id == payload.configuration.name else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container network list contained conflicting resource identities."
                    )
                }
                if let configurationID = payload.configuration.id {
                    try AppleContainerInfrastructureDecoding.requireString(
                        configurationID,
                        operation: "Apple container network list",
                        maximumBytes: maximumStringBytes
                    )
                    guard configurationID == payload.id else {
                        throw RuntimeAdapterError.outputParseFailed(
                            "Apple container network list contained conflicting resource identities."
                        )
                    }
                }
                guard seenIdentifiers.insert(payload.id).inserted else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container network list contained a duplicate resource identity."
                    )
                }

                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.plugin,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.validateMetadata(
                    payload.configuration.labels,
                    operation: "Apple container network list labels",
                    maximumEntries: maximumMetadataEntries,
                    maximumStringBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.validateMetadata(
                    payload.configuration.options,
                    operation: "Apple container network list options",
                    maximumEntries: maximumMetadataEntries,
                    maximumStringBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.status.ipv4Subnet,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.status.ipv4Gateway,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.validateOptionalString(
                    payload.status.ipv6Subnet,
                    operation: "Apple container network list",
                    maximumBytes: maximumStringBytes
                )

                return AppleContainerNetworkEvidence(
                    id: payload.id,
                    name: payload.configuration.name,
                    mode: payload.configuration.mode,
                    creationDate: payload.configuration.creationDate,
                    plugin: payload.configuration.plugin,
                    labels: payload.configuration.labels,
                    options: payload.configuration.options,
                    ipv4Subnet: payload.status.ipv4Subnet,
                    ipv4Gateway: payload.status.ipv4Gateway,
                    ipv6Subnet: payload.status.ipv6Subnet
                )
            }
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container network list did not match a supported typed JSON schema."
            )
        }
    }

    private struct NetworkPayload: Decodable {
        let id: String
        let configuration: Configuration
        let status: Status
    }

    private struct Configuration: Decodable {
        let name: String
        let id: String?
        let mode: AppleContainerNetworkMode
        let creationDate: Date
        let labels: [String: String]
        let plugin: String
        let options: [String: String]
    }

    private struct Status: Decodable {
        let ipv4Subnet: String
        let ipv4Gateway: String
        let ipv6Subnet: String?
    }
}

public enum AppleContainerVolumeListParser {
    public static let maximumBytes = 1 * 1_024 * 1_024
    public static let maximumEntries = 256
    public static let maximumStringBytes = 4_096
    public static let maximumMetadataEntries = 128

    public static func parse(
        _ text: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerVolumeEvidence] {
        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                text,
                operation: "Apple container volume list",
                maximumBytes: maximumBytes
            )
            let payloads = try AppleContainerInfrastructureDecoding.decoder.decode(
                [VolumePayload].self,
                from: data
            )
            guard payloads.count <= maximumEntries else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container volume list exceeded the \(maximumEntries)-entry codec limit."
                )
            }

            var seenIdentifiers = Set<String>()
            return try payloads.map { payload in
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.id,
                    operation: "Apple container volume list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.name,
                    operation: "Apple container volume list",
                    maximumBytes: maximumStringBytes
                )
                guard payload.id == payload.configuration.name else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container volume list contained conflicting resource identities."
                    )
                }
                if let configurationID = payload.configuration.id {
                    try AppleContainerInfrastructureDecoding.requireString(
                        configurationID,
                        operation: "Apple container volume list",
                        maximumBytes: maximumStringBytes
                    )
                    guard configurationID == payload.id else {
                        throw RuntimeAdapterError.outputParseFailed(
                            "Apple container volume list contained conflicting resource identities."
                        )
                    }
                }
                guard seenIdentifiers.insert(payload.id).inserted else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container volume list contained a duplicate resource identity."
                    )
                }

                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.driver,
                    operation: "Apple container volume list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.format,
                    operation: "Apple container volume list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.configuration.source,
                    operation: "Apple container volume list",
                    maximumBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.validateMetadata(
                    payload.configuration.labels,
                    operation: "Apple container volume list labels",
                    maximumEntries: maximumMetadataEntries,
                    maximumStringBytes: maximumStringBytes
                )
                try AppleContainerInfrastructureDecoding.validateMetadata(
                    payload.configuration.options,
                    operation: "Apple container volume list options",
                    maximumEntries: maximumMetadataEntries,
                    maximumStringBytes: maximumStringBytes
                )

                return AppleContainerVolumeEvidence(
                    id: payload.id,
                    name: payload.configuration.name,
                    driver: payload.configuration.driver,
                    format: payload.configuration.format,
                    source: payload.configuration.source,
                    creationDate: payload.configuration.creationDate,
                    labels: payload.configuration.labels,
                    options: payload.configuration.options,
                    sizeInBytes: payload.configuration.sizeInBytes
                )
            }
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container volume list did not match a supported typed JSON schema."
            )
        }
    }

    private struct VolumePayload: Decodable {
        let id: String
        let configuration: Configuration
    }

    private struct Configuration: Decodable {
        let name: String
        let id: String?
        let driver: String
        let format: String
        let source: String
        let creationDate: Date
        let labels: [String: String]
        let options: [String: String]
        let sizeInBytes: UInt64?
    }
}

public enum AppleContainerMachineListParser {
    public static let maximumBytes = 512 * 1_024
    public static let maximumEntries = 64
    public static let maximumStringBytes = 4_096

    public static func parse(
        _ text: String,
        redactionPolicy: RuntimeRedactionPolicy = .default
    ) throws -> [AppleContainerMachineEvidence] {
        do {
            let data = try AppleContainerStructuredOutput.validatedJSONData(
                text,
                operation: "Apple container machine list",
                maximumBytes: maximumBytes
            )
            let payloads = try AppleContainerInfrastructureDecoding.decoder.decode(
                [MachinePayload].self,
                from: data
            )
            guard payloads.count <= maximumEntries else {
                throw RuntimeAdapterError.outputParseFailed(
                    "Apple container machine list exceeded the \(maximumEntries)-entry codec limit."
                )
            }

            var seenIdentifiers = Set<String>()
            var defaultIdentifier: String?
            return try payloads.map { payload in
                try AppleContainerInfrastructureDecoding.requireString(
                    payload.id,
                    operation: "Apple container machine list",
                    maximumBytes: maximumStringBytes
                )
                guard seenIdentifiers.insert(payload.id).inserted else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container machine list contained a duplicate resource identity."
                    )
                }
                if payload.isDefault {
                    guard defaultIdentifier == nil else {
                        throw RuntimeAdapterError.outputParseFailed(
                            "Apple container machine list contained conflicting default identities."
                        )
                    }
                    defaultIdentifier = payload.id
                }
                try AppleContainerInfrastructureDecoding.validateOptionalString(
                    payload.ipAddress,
                    operation: "Apple container machine list",
                    maximumBytes: maximumStringBytes
                )
                guard payload.cpuCount > 0, payload.memoryBytes > 0 else {
                    throw RuntimeAdapterError.outputParseFailed(
                        "Apple container machine list contained invalid resource allocation evidence."
                    )
                }

                return AppleContainerMachineEvidence(
                    id: payload.id,
                    status: payload.status,
                    isDefault: payload.isDefault,
                    ipAddress: payload.ipAddress,
                    cpuCount: payload.cpuCount,
                    memoryBytes: payload.memoryBytes,
                    diskSizeBytes: payload.diskSizeBytes,
                    creationDate: payload.creationDate
                )
            }
        } catch let error as RuntimeAdapterError {
            throw error.redacted(using: redactionPolicy)
        } catch {
            throw RuntimeAdapterError.outputParseFailed(
                "Apple container machine list did not match a supported typed JSON schema."
            )
        }
    }

    private struct MachinePayload: Decodable {
        let id: String
        let status: AppleContainerMachineStatus
        let isDefault: Bool
        let ipAddress: String?
        let cpuCount: Int
        let memoryBytes: UInt64
        let diskSizeBytes: UInt64?
        let creationDate: Date?

        private enum CodingKeys: String, CodingKey {
            case id
            case status
            case isDefault = "default"
            case ipAddress
            case cpuCount = "cpus"
            case memoryBytes = "memory"
            case diskSizeBytes = "diskSize"
            case creationDate = "createdDate"
        }
    }
}

private enum AppleContainerInfrastructureDecoding {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func requireString(
        _ value: String,
        operation: String,
        maximumBytes: Int
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw RuntimeAdapterError.outputParseFailed(
                "\(operation) contained an empty or oversized semantic string."
            )
        }
    }

    static func validateOptionalString(
        _ value: String?,
        operation: String,
        maximumBytes: Int
    ) throws {
        guard let value else { return }
        try requireString(value, operation: operation, maximumBytes: maximumBytes)
    }

    static func validateMetadata(
        _ metadata: [String: String],
        operation: String,
        maximumEntries: Int,
        maximumStringBytes: Int
    ) throws {
        guard metadata.count <= maximumEntries else {
            throw RuntimeAdapterError.outputParseFailed(
                "\(operation) exceeded the \(maximumEntries)-entry codec limit."
            )
        }
        for (key, value) in metadata {
            try requireString(key, operation: operation, maximumBytes: maximumStringBytes)
            guard value.utf8.count <= maximumStringBytes else {
                throw RuntimeAdapterError.outputParseFailed(
                    "\(operation) contained an oversized metadata value."
                )
            }
        }
    }
}
