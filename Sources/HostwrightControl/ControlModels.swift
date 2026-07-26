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
    case image
    case registry
    case volume
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
    public let imageOperation: String?
    public let imageReferences: [String]?
    public let imageTargetReference: String?
    public let imageContextPath: String?
    public let imageFilePath: String?
    public let imageArchivePath: String?
    public let imagePlatform: String?
    public let imageOffline: Bool?
    public let imageNoCache: Bool?
    public let imageProgress: String?
    public let imageMaximumBytes: Int64?
    public let imageTargetBytes: Int64?
    public let imageRetentionSeconds: Int?
    public let imageMaximumDeletions: Int?
    public let volumeOperation: String?
    public let volumeIDs: [String]?
    public let volumeResourceID: String?
    public let volumeName: String?
    public let volumeTargetVolumeID: String?
    public let volumeReferenceID: String?
    public let volumeOwner: String?
    public let volumeOutputPath: String?
    public let volumeKeyReference: String?
    public let volumeRestoreTargets: [String]?
    public let volumeIdempotencyKey: String?
    public let volumeRemoteS3Endpoint: String?
    public let volumeRemoteS3Bucket: String?
    public let volumeRemoteS3Region: String?
    public let volumeRemoteS3Prefix: String?
    public let volumeRemoteS3AccessKeyReference: String?
    public let volumeRemoteS3SecretKeyReference: String?
    public let registryReferrerOperation: String?
    public let registryServer: String?
    public let registryRepository: String?
    public let registrySubjectDigest: String?
    public let registryArtifactType: String?
    public let registryTargetServer: String?
    public let registryTargetRepository: String?
    public let registryDiscoveryID: String?
    public let registryReferrerDigest: String?
    public let registryLeaseID: String?
    public let registryFencingToken: String?
    public let registryOwnerID: String?
    public let registryExpiresAt: String?
    public let registryOperationGroupID: String?
    public let registryOffline: Bool?
    public let registryTrustOperation: String?
    public let registrySBOMOperation: String?
    public let registryVulnerabilityOperation: String?
    public let registryProvenanceOperation: String?
    public let registrySBOMArchivePath: String?
    public let registrySBOMFormat: String?
    public let registrySBOMOutputPath: String?
    public let registryProvenanceArchivePath: String?
    public let registryProvenanceBuildRecordPath: String?
    public let registryProvenanceDescriptorDigest: String?
    public let registryProvenanceReferrerDigest: String?
    public let registryProvenanceSignerID: String?
    public let registryProvenanceSigningKeyReference: String?
    public let registrySubjectManifestPath: String?
    public let registryCosignPath: String?
    public let registryServiceName: String?
    public let registryApprovalRecordPath: String?
    public let registryExceptionID: String?

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
        parallelism: Int? = nil,
        imageOperation: String? = nil,
        imageReferences: [String]? = nil,
        imageTargetReference: String? = nil,
        imageContextPath: String? = nil,
        imageFilePath: String? = nil,
        imageArchivePath: String? = nil,
        imagePlatform: String? = nil,
        imageOffline: Bool? = nil,
        imageNoCache: Bool? = nil,
        imageProgress: String? = nil,
        imageMaximumBytes: Int64? = nil,
        imageTargetBytes: Int64? = nil,
        imageRetentionSeconds: Int? = nil,
        imageMaximumDeletions: Int? = nil,
        volumeOperation: String? = nil,
        volumeIDs: [String]? = nil,
        volumeResourceID: String? = nil,
        volumeName: String? = nil,
        volumeTargetVolumeID: String? = nil,
        volumeReferenceID: String? = nil,
        volumeOwner: String? = nil,
        volumeOutputPath: String? = nil,
        volumeKeyReference: String? = nil,
        volumeRestoreTargets: [String]? = nil,
        volumeIdempotencyKey: String? = nil,
        volumeRemoteS3Endpoint: String? = nil,
        volumeRemoteS3Bucket: String? = nil,
        volumeRemoteS3Region: String? = nil,
        volumeRemoteS3Prefix: String? = nil,
        volumeRemoteS3AccessKeyReference: String? = nil,
        volumeRemoteS3SecretKeyReference: String? = nil,
        registryReferrerOperation: String? = nil,
        registryServer: String? = nil,
        registryRepository: String? = nil,
        registrySubjectDigest: String? = nil,
        registryArtifactType: String? = nil,
        registryTargetServer: String? = nil,
        registryTargetRepository: String? = nil,
        registryDiscoveryID: String? = nil,
        registryReferrerDigest: String? = nil,
        registryLeaseID: String? = nil,
        registryFencingToken: String? = nil,
        registryOwnerID: String? = nil,
        registryExpiresAt: String? = nil,
        registryOperationGroupID: String? = nil,
        registryOffline: Bool? = nil,
        registryTrustOperation: String? = nil,
        registrySBOMOperation: String? = nil,
        registryVulnerabilityOperation: String? = nil,
        registryProvenanceOperation: String? = nil,
        registrySBOMArchivePath: String? = nil,
        registrySBOMFormat: String? = nil,
        registrySBOMOutputPath: String? = nil,
        registryProvenanceArchivePath: String? = nil,
        registryProvenanceBuildRecordPath: String? = nil,
        registryProvenanceDescriptorDigest: String? = nil,
        registryProvenanceReferrerDigest: String? = nil,
        registryProvenanceSignerID: String? = nil,
        registryProvenanceSigningKeyReference: String? = nil,
        registrySubjectManifestPath: String? = nil,
        registryCosignPath: String? = nil,
        registryServiceName: String? = nil,
        registryApprovalRecordPath: String? = nil,
        registryExceptionID: String? = nil
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
        self.imageOperation = imageOperation
        self.imageReferences = imageReferences
        self.imageTargetReference = imageTargetReference
        self.imageContextPath = imageContextPath
        self.imageFilePath = imageFilePath
        self.imageArchivePath = imageArchivePath
        self.imagePlatform = imagePlatform
        self.imageOffline = imageOffline
        self.imageNoCache = imageNoCache
        self.imageProgress = imageProgress
        self.imageMaximumBytes = imageMaximumBytes
        self.imageTargetBytes = imageTargetBytes
        self.imageRetentionSeconds = imageRetentionSeconds
        self.imageMaximumDeletions = imageMaximumDeletions
        self.volumeOperation = volumeOperation
        self.volumeIDs = volumeIDs
        self.volumeResourceID = volumeResourceID
        self.volumeName = volumeName
        self.volumeTargetVolumeID = volumeTargetVolumeID
        self.volumeReferenceID = volumeReferenceID
        self.volumeOwner = volumeOwner
        self.volumeOutputPath = volumeOutputPath
        self.volumeKeyReference = volumeKeyReference
        self.volumeRestoreTargets = volumeRestoreTargets
        self.volumeIdempotencyKey = volumeIdempotencyKey
        self.volumeRemoteS3Endpoint = volumeRemoteS3Endpoint
        self.volumeRemoteS3Bucket = volumeRemoteS3Bucket
        self.volumeRemoteS3Region = volumeRemoteS3Region
        self.volumeRemoteS3Prefix = volumeRemoteS3Prefix
        self.volumeRemoteS3AccessKeyReference =
            volumeRemoteS3AccessKeyReference
        self.volumeRemoteS3SecretKeyReference =
            volumeRemoteS3SecretKeyReference
        self.registryReferrerOperation = registryReferrerOperation
        self.registryServer = registryServer
        self.registryRepository = registryRepository
        self.registrySubjectDigest = registrySubjectDigest
        self.registryArtifactType = registryArtifactType
        self.registryTargetServer = registryTargetServer
        self.registryTargetRepository = registryTargetRepository
        self.registryDiscoveryID = registryDiscoveryID
        self.registryReferrerDigest = registryReferrerDigest
        self.registryLeaseID = registryLeaseID
        self.registryFencingToken = registryFencingToken
        self.registryOwnerID = registryOwnerID
        self.registryExpiresAt = registryExpiresAt
        self.registryOperationGroupID = registryOperationGroupID
        self.registryOffline = registryOffline
        self.registryTrustOperation = registryTrustOperation
        self.registrySBOMOperation = registrySBOMOperation
        self.registryVulnerabilityOperation =
            registryVulnerabilityOperation
        self.registryProvenanceOperation =
            registryProvenanceOperation
        self.registrySBOMArchivePath = registrySBOMArchivePath
        self.registrySBOMFormat = registrySBOMFormat
        self.registrySBOMOutputPath = registrySBOMOutputPath
        self.registryProvenanceArchivePath =
            registryProvenanceArchivePath
        self.registryProvenanceBuildRecordPath =
            registryProvenanceBuildRecordPath
        self.registryProvenanceDescriptorDigest =
            registryProvenanceDescriptorDigest
        self.registryProvenanceReferrerDigest =
            registryProvenanceReferrerDigest
        self.registryProvenanceSignerID =
            registryProvenanceSignerID
        self.registryProvenanceSigningKeyReference =
            registryProvenanceSigningKeyReference
        self.registrySubjectManifestPath = registrySubjectManifestPath
        self.registryCosignPath = registryCosignPath
        self.registryServiceName = registryServiceName
        self.registryApprovalRecordPath = registryApprovalRecordPath
        self.registryExceptionID = registryExceptionID
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
