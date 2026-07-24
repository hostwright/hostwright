import Foundation
import HostwrightCore

public enum LocalControlOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case plan
    case status
    case events
    case recovery
    case doctor
    case up
    case down
    case run
    case start
    case stop
    case restart
    case rm
    case update
}

public struct LocalControlRequest: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let requestID: String
    public let operation: LocalControlOperation
    public let project: String?
    public let eventType: String?
    public let service: String?
    public let severity: String?
    public let limit: Int?
    public let sort: String?
    public let services: [String]?
    public let dryRun: Bool?
    public let confirmPlan: String?
    public let runtimeProvider: String?
    public let timeout: Int?
    public let parallelism: Int?

    public init(
        apiVersion: Int = HostwrightContractVersions.controlAPI,
        requestID: String,
        operation: LocalControlOperation,
        project: String? = nil,
        eventType: String? = nil,
        service: String? = nil,
        severity: String? = nil,
        limit: Int? = nil,
        sort: String? = nil,
        services: [String]? = nil,
        dryRun: Bool? = nil,
        confirmPlan: String? = nil,
        runtimeProvider: String? = nil,
        timeout: Int? = nil,
        parallelism: Int? = nil
    ) {
        self.apiVersion = apiVersion
        self.requestID = requestID
        self.operation = operation
        self.project = project
        self.eventType = eventType
        self.service = service
        self.severity = severity
        self.limit = limit
        self.sort = sort
        self.services = services
        self.dryRun = dryRun
        self.confirmPlan = confirmPlan
        self.runtimeProvider = runtimeProvider
        self.timeout = timeout
        self.parallelism = parallelism
    }
}

public struct LocalControlConfiguration: Equatable, Sendable {
    public let manifestPath: String
    public let stateDatabasePath: String?
    public let teamProfilePath: String?

    public init(
        manifestPath: String,
        stateDatabasePath: String? = nil,
        teamProfilePath: String? = nil
    ) {
        self.manifestPath = manifestPath
        self.stateDatabasePath = stateDatabasePath
        self.teamProfilePath = teamProfilePath
    }
}

public struct LocalControlResponse: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let requestID: String?
    public let operation: LocalControlOperation?
    public let success: Bool
    public let exitCode: Int32
    public let result: ControlJSONValue?
    public let error: ControlJSONValue?

    public init(
        apiVersion: Int = HostwrightContractVersions.controlAPI,
        requestID: String?,
        operation: LocalControlOperation?,
        success: Bool,
        exitCode: Int32,
        result: ControlJSONValue? = nil,
        error: ControlJSONValue? = nil
    ) {
        self.apiVersion = apiVersion
        self.requestID = requestID
        self.operation = operation
        self.success = success
        self.exitCode = exitCode
        self.result = result
        self.error = error
    }
}

public struct LocalControlRunResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: String
    public let exitCode: Int32

    public init(standardOutput: Data = Data(), standardError: String = "", exitCode: Int32 = 0) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public enum LocalControlExitCode: Int32, Equatable, Sendable {
    case success = 0
    case usage = 64
    case invalidRequest = 65
    case unavailable = 66
    case executionFailed = 72
}

public enum ControlJSONValue: Codable, Equatable, Sendable {
    case object([String: ControlJSONValue])
    case array([ControlJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ControlJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ControlJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}
