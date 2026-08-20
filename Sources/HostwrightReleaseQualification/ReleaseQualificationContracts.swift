import CryptoKit
import Foundation
import HostwrightCore

public enum ReleaseQualificationContractError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalid(field: String, reason: String)
    case unsupportedSchemaVersion(Int)
    case nonCanonicalJSON
    case oversizedInput
    case unsafePath
    case schemaMismatch
    case ledgerConflict
    case tamperedEvidence
    case staleEvidence
    case cancelled

    public var description: String {
        switch self {
        case .invalid(let field, let reason):
            "Invalid \(field): \(reason)"
        case .unsupportedSchemaVersion(let version):
            "Unsupported release-qualification schema version \(version)."
        case .nonCanonicalJSON:
            "Release-qualification JSON is not canonical."
        case .oversizedInput:
            "Release-qualification input exceeds the bounded limit."
        case .unsafePath:
            "Release-qualification path is unsafe."
        case .schemaMismatch:
            "Release-qualification document kind or schema does not match."
        case .ledgerConflict:
            "Release-qualification ledger replay conflicts with an existing run."
        case .tamperedEvidence:
            "Release-qualification evidence integrity validation failed."
        case .staleEvidence:
            "Release-qualification evidence no longer matches the current environment."
        case .cancelled:
            "Release-qualification operation was cancelled."
        }
    }
}

public protocol ReleaseQualificationValidating {
    func validate() throws
}

public enum ReleaseQualificationLimits {
    public static let schemaVersion = 1
    public static let phase08ReleaseCommit =
        "00f95eaabd105f17f61727d2a9899db919ad3d9f"
    public static let maximumJSONBytes = 8 * 1_024 * 1_024
    public static let maximumCommandCount = 256
    public static let maximumCommandArguments = 64
    public static let maximumCommandArgumentBytes = 4_096
    public static let maximumToolFacts = 64
    public static let maximumMatrixCells = 256
    public static let maximumBlockers = 128
    public static let maximumArtifacts = 256
    public static let maximumOutputBytes = 1 * 1_024 * 1_024
    public static let maximumSourceFileBytes = 4 * 1_024 * 1_024
    public static let maximumSourceScanBytes = 64 * 1_024 * 1_024
}

public struct ReleaseQualificationSemanticVersion:
    Codable, Comparable, Equatable, Hashable, Sendable, CustomStringConvertible,
    ReleaseQualificationValidating
{
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        precondition(major >= 0 && minor >= 0 && patch >= 0)
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(parsing value: String, allowingTwoComponents: Bool = false) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 || (allowingTwoComponents && components.count == 2),
              components.allSatisfy({ component in
                  !component.isEmpty &&
                      (component == "0" || !component.hasPrefix("0")) &&
                      component.allSatisfy { $0.isNumber }
              }),
              let major = Int(components[0]),
              let minor = Int(components[1]),
              major >= 0,
              minor >= 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "version",
                reason: "expected a bounded semantic version"
            )
        }
        let patch: Int
        if components.count == 3 {
            guard let parsed = Int(components[2]), parsed >= 0 else {
                throw ReleaseQualificationContractError.invalid(
                    field: "version",
                    reason: "patch is not a non-negative integer"
                )
            }
            patch = parsed
        } else {
            patch = 0
        }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public func validate() throws {
        guard major >= 0, minor >= 0, patch >= 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "version",
                reason: "components must be non-negative"
            )
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        try self.init(parsing: value)
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct ReleaseQualificationCommit:
    Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
    ReleaseQualificationValidating
{
    public let value: String

    public init(_ value: String) throws {
        guard value.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              value != String(repeating: "0", count: 40) else {
            throw ReleaseQualificationContractError.invalid(
                field: "sourceCommit",
                reason: "expected a non-zero lowercase 40-hex commit"
            )
        }
        self.value = value
    }

    public var description: String { value }

    public func validate() throws {
        _ = try Self(value)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ReleaseQualificationSHA256:
    Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
    ReleaseQualificationValidating
{
    public let value: String

    public init(_ value: String) throws {
        guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ReleaseQualificationContractError.invalid(
                field: "sha256",
                reason: "expected lowercase 64-hex SHA-256"
            )
        }
        self.value = value
    }

    public init(data: Data) {
        value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(validatedValue: String) {
        value = validatedValue
    }

    public var description: String { value }

    public func validate() throws { _ = try Self(value) }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ReleaseQualificationTimestamp:
    Codable, Equatable, Hashable, Sendable, CustomStringConvertible,
    ReleaseQualificationValidating
{
    public let value: String

    public init(_ value: String) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: value) != nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ReleaseQualificationContractError.invalid(
                field: "timestamp",
                reason: "expected RFC 3339 timestamp"
            )
        }
        self.value = value
    }

    public init(date: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        value = formatter.string(from: date)
    }

    public var description: String { value }

    public func validate() throws { _ = try Self(value) }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ReleaseQualificationArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64 = "x86_64"
    case unknown
}

public enum ReleaseQualificationHardwareCell: String, Codable, CaseIterable, Sendable {
    case appleSilicon = "apple-silicon"
}

public enum ReleaseQualificationProvider: String, Codable, CaseIterable, Sendable {
    case appleContainerCLI = "apple-container-cli"
    case appleContainerization = "apple-containerization"
}

public enum ReleaseQualificationClientFamily: String, Codable, CaseIterable, Sendable {
    case kubernetes
    case docker
    case compose
    case podman
    case testcontainers
    case swiftSDK = "swift-sdk"
    case xcode
    case vscode
    case jetbrains
}

public enum ReleaseQualificationTool: String, Codable, CaseIterable, Sendable {
    case git
    case swVers = "sw_vers"
    case uname
    case sysctl
    case swift
    case swiftc
    case appleContainer = "apple-container"
    case containerizationFramework = "containerization-framework"
    case xcodebuild
    case kubectl
    case docker
    case podman
    case brew
    case clang
    case codesign
    case notarytool
    case spctl
    case security
    case semgrep
    case swiftlint
    case licenseScanner = "license-scanner"
}

public enum ReleaseQualificationFactStatus: String, Codable, Sendable {
    case available
    case unavailable
    case malformed
}

public enum ReleaseQualificationUnsupportedReason: String, Codable, CaseIterable, Sendable {
    case unknownFact
    case unavailableFact
    case malformedFact
    case sourceCommitUnavailable
    case dirtySource
    case futureVersion
    case unsupportedVersion
    case unsupportedMacOSVersion
    case unsupportedArchitecture
    case unsupportedHardware
    case unsupportedProvider
    case unsupportedClient
    case unsupportedMatrixCell
    case mixedVersions
    case missingTool
    case missingCorpus
    case corpusMismatch
    case phase08ReleaseUnavailable
    case outputLimitExceeded
    case unsafePath
    case missingExplicitAuthority
    case liveRuntimePhase08Boundary
    case heavyLaneNotExecutable
    case sanitizerUnavailable
    case fuzzingProviderUnavailable
    case dependencyUnavailable
    case sastToolUnavailable
    case secretScanUnavailable
    case licenseMetadataUnavailable
    case externalAssessmentUnavailable
    case signingNotAuthorized
    case publicationNotAuthorized
    case simulatedEvidence
    case fixtureEvidence
    case mockEvidence
    case staleEvidence
    case tamperedEvidence
    case artifactOwnershipUnproven
    case unmanagedPath
    case cancellation
    case futureSchema
    case schemaMismatch
    case noSupportedClaim
}

public struct ReleaseQualificationFactAvailability:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let status: ReleaseQualificationFactStatus
    public let reason: ReleaseQualificationUnsupportedReason?

    public init(
        status: ReleaseQualificationFactStatus,
        reason: ReleaseQualificationUnsupportedReason? = nil
    ) {
        self.status = status
        self.reason = reason
    }

    public func validate() throws {
        switch status {
        case .available:
            guard reason == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "factAvailability",
                    reason: "available facts may not carry a blocker"
                )
            }
        case .unavailable, .malformed:
            guard reason != nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "factAvailability",
                    reason: "unavailable facts require an exact reason"
                )
            }
        }
    }
}

public struct ReleaseQualificationCommandIdentity:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String
    public let purpose: String

    public init(
        executablePath: String,
        arguments: [String],
        workingDirectory: String,
        purpose: String
    ) throws {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.purpose = purpose
        try validate()
    }

    public func validate() throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(executablePath),
              ReleaseQualificationPath.isNormalizedAbsolute(workingDirectory),
              !purpose.isEmpty,
              purpose.utf8.count <= 256,
              purpose.rangeOfCharacter(from: .controlCharacters) == nil,
              arguments.count <= ReleaseQualificationLimits.maximumCommandArguments,
              arguments.allSatisfy({ argument in
                  !argument.isEmpty &&
                      argument.utf8.count <= ReleaseQualificationLimits.maximumCommandArgumentBytes &&
                      argument.rangeOfCharacter(from: .controlCharacters) == nil &&
                      !ReleaseQualificationSensitiveArgument.isSensitive(argument)
              }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "command",
                reason: "command identity is unsafe or exceeds its bound"
            )
        }
    }
}

public enum ReleaseQualificationSensitiveArgument {
    public static func isSensitive(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("authorization") ||
            lowercased.contains("bearer ") ||
            lowercased.contains("password") ||
            lowercased.contains("secret") ||
            lowercased.contains("private_key") ||
            lowercased.contains("private-key") ||
            lowercased.contains("access_token") ||
            lowercased.contains("access-token") ||
            lowercased.contains("refresh_token") ||
            lowercased.contains("refresh-token") ||
            lowercased.contains("api_key") ||
            lowercased.contains("api-key") ||
            lowercased.contains("credential")
    }
}

public struct ReleaseQualificationCommandObservation:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let identity: ReleaseQualificationCommandIdentity
    public let startedAt: ReleaseQualificationTimestamp
    public let endedAt: ReleaseQualificationTimestamp
    public let durationMilliseconds: Int
    public let exitStatus: Int32
    public let standardOutputSHA256: ReleaseQualificationSHA256
    public let standardErrorSHA256: ReleaseQualificationSHA256
    public let standardOutputBytes: Int
    public let standardErrorBytes: Int
    public let standardOutputTruncated: Bool
    public let standardErrorTruncated: Bool

    public init(
        identity: ReleaseQualificationCommandIdentity,
        startedAt: ReleaseQualificationTimestamp,
        endedAt: ReleaseQualificationTimestamp,
        durationMilliseconds: Int,
        exitStatus: Int32,
        standardOutputSHA256: ReleaseQualificationSHA256,
        standardErrorSHA256: ReleaseQualificationSHA256,
        standardOutputBytes: Int,
        standardErrorBytes: Int,
        standardOutputTruncated: Bool = false,
        standardErrorTruncated: Bool = false
    ) {
        self.identity = identity
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.exitStatus = exitStatus
        self.standardOutputSHA256 = standardOutputSHA256
        self.standardErrorSHA256 = standardErrorSHA256
        self.standardOutputBytes = standardOutputBytes
        self.standardErrorBytes = standardErrorBytes
        self.standardOutputTruncated = standardOutputTruncated
        self.standardErrorTruncated = standardErrorTruncated
    }

    public func validate() throws {
        try identity.validate()
        try startedAt.validate()
        try endedAt.validate()
        try standardOutputSHA256.validate()
        try standardErrorSHA256.validate()
        guard durationMilliseconds >= 0,
              durationMilliseconds <= 86_400_000,
              standardOutputBytes >= 0,
              standardErrorBytes >= 0,
              standardOutputBytes <= ReleaseQualificationLimits.maximumOutputBytes,
              standardErrorBytes <= ReleaseQualificationLimits.maximumOutputBytes else {
            throw ReleaseQualificationContractError.invalid(
                field: "commandObservation",
                reason: "duration or output size is outside the bound"
            )
        }
    }
}

public struct ReleaseQualificationSourceFacts:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let availability: ReleaseQualificationFactAvailability
    public let commit: ReleaseQualificationCommit?
    public let dirty: Bool?
    public let dirtyStateSHA256: ReleaseQualificationSHA256?

    public init(
        availability: ReleaseQualificationFactAvailability,
        commit: ReleaseQualificationCommit?,
        dirty: Bool?,
        dirtyStateSHA256: ReleaseQualificationSHA256?
    ) {
        self.availability = availability
        self.commit = commit
        self.dirty = dirty
        self.dirtyStateSHA256 = dirtyStateSHA256
    }

    public func validate() throws {
        try availability.validate()
        switch availability.status {
        case .available:
            guard commit != nil, dirty != nil, dirtyStateSHA256 != nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "sourceFacts",
                    reason: "available source facts are incomplete"
                )
            }
        case .unavailable, .malformed:
            guard commit == nil, dirty == nil, dirtyStateSHA256 == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "sourceFacts",
                    reason: "unavailable source facts may not carry partial values"
                )
            }
        }
    }
}

public struct ReleaseQualificationPhase08ReleaseFacts:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let availability: ReleaseQualificationFactAvailability
    public let releaseCommit: ReleaseQualificationCommit?
    public let sourceContainsRelease: Bool?

    public init(
        availability: ReleaseQualificationFactAvailability,
        releaseCommit: ReleaseQualificationCommit?,
        sourceContainsRelease: Bool?
    ) {
        self.availability = availability
        self.releaseCommit = releaseCommit
        self.sourceContainsRelease = sourceContainsRelease
    }

    public func validate() throws {
        try availability.validate()
        switch availability.status {
        case .available:
            guard releaseCommit?.value == ReleaseQualificationLimits.phase08ReleaseCommit,
                  sourceContainsRelease != nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "phase08ReleaseFacts",
                    reason: "available Phase 08 release facts are incomplete or unexpected"
                )
            }
        case .unavailable, .malformed:
            guard releaseCommit == nil, sourceContainsRelease == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "phase08ReleaseFacts",
                    reason: "unavailable Phase 08 release facts may not carry partial values"
                )
            }
        }
    }
}

public struct ReleaseQualificationHostFacts:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let availability: ReleaseQualificationFactAvailability
    public let macOSVersion: ReleaseQualificationSemanticVersion?
    public let build: String?
    public let architecture: ReleaseQualificationArchitecture?
    public let hardwareModel: String?
    public let memoryBytes: Int64?
    public let arm64Capability: Bool?

    public init(
        availability: ReleaseQualificationFactAvailability,
        macOSVersion: ReleaseQualificationSemanticVersion?,
        build: String?,
        architecture: ReleaseQualificationArchitecture?,
        hardwareModel: String?,
        memoryBytes: Int64?,
        arm64Capability: Bool?
    ) {
        self.availability = availability
        self.macOSVersion = macOSVersion
        self.build = build
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.memoryBytes = memoryBytes
        self.arm64Capability = arm64Capability
    }

    public func validate() throws {
        try availability.validate()
        switch availability.status {
        case .available:
            guard macOSVersion != nil,
                  build.map({ !$0.isEmpty && $0.utf8.count <= 128 }) == true,
                  architecture != nil,
                  hardwareModel.map({ !$0.isEmpty && $0.utf8.count <= 256 }) == true,
                  memoryBytes.map({ $0 > 0 }) == true,
                  arm64Capability != nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "hostFacts",
                    reason: "available host facts are incomplete"
                )
            }
        case .unavailable, .malformed:
            guard macOSVersion == nil,
                  build == nil,
                  architecture == nil,
                  hardwareModel == nil,
                  memoryBytes == nil,
                  arm64Capability == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "hostFacts",
                    reason: "unavailable host facts may not carry partial values"
                )
            }
        }
    }
}

public enum ReleaseQualificationFactOrigin: String, Codable, Sendable {
    case process
    case committedManifest = "committed-manifest"
    case packageResolved = "package-resolved"
}

public struct ReleaseQualificationToolFact:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let tool: ReleaseQualificationTool
    public let origin: ReleaseQualificationFactOrigin
    public let availability: ReleaseQualificationFactAvailability
    public let executablePath: String?
    public let version: ReleaseQualificationSemanticVersion?
    public let rawOutputSHA256: ReleaseQualificationSHA256?
    public let command: ReleaseQualificationCommandIdentity?

    public init(
        tool: ReleaseQualificationTool,
        origin: ReleaseQualificationFactOrigin,
        availability: ReleaseQualificationFactAvailability,
        executablePath: String?,
        version: ReleaseQualificationSemanticVersion?,
        rawOutputSHA256: ReleaseQualificationSHA256?,
        command: ReleaseQualificationCommandIdentity?
    ) {
        self.tool = tool
        self.origin = origin
        self.availability = availability
        self.executablePath = executablePath
        self.version = version
        self.rawOutputSHA256 = rawOutputSHA256
        self.command = command
    }

    public func validate() throws {
        try availability.validate()
        if let executablePath {
            guard ReleaseQualificationPath.isNormalizedAbsolute(executablePath) else {
                throw ReleaseQualificationContractError.invalid(
                    field: "toolFact.executablePath",
                    reason: "executable path is not normalized"
                )
            }
        }
        if let command { try command.validate() }
        switch availability.status {
        case .available:
            guard version != nil, rawOutputSHA256 != nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "toolFact",
                    reason: "available tool facts require version and raw-output digest"
                )
            }
        case .unavailable, .malformed:
            guard version == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "toolFact",
                    reason: "unavailable tool facts may not carry a version"
                )
            }
        }
    }
}

public struct ReleaseQualificationDetectedEnvironment:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let source: ReleaseQualificationSourceFacts
    public let phase08Release: ReleaseQualificationPhase08ReleaseFacts?
    public let host: ReleaseQualificationHostFacts
    public let tools: [ReleaseQualificationToolFact]
    public let commands: [ReleaseQualificationCommandObservation]

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        source: ReleaseQualificationSourceFacts,
        phase08Release: ReleaseQualificationPhase08ReleaseFacts? = nil,
        host: ReleaseQualificationHostFacts,
        tools: [ReleaseQualificationToolFact],
        commands: [ReleaseQualificationCommandObservation]
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.phase08Release = phase08Release
        self.host = host
        self.tools = tools.sorted { $0.tool.rawValue < $1.tool.rawValue }
        self.commands = commands
    }

    public var fingerprint: ReleaseQualificationSHA256 {
        ReleaseQualificationSHA256(
            data: (try? ReleaseQualificationJSON.encode(self)) ?? Data()
        )
    }

    public func tool(_ tool: ReleaseQualificationTool) -> ReleaseQualificationToolFact? {
        tools.first { $0.tool == tool }
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
            throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
        }
        try source.validate()
        if let phase08Release { try phase08Release.validate() }
        try host.validate()
        guard tools.count <= ReleaseQualificationLimits.maximumToolFacts,
              tools.map(\.tool).count == Set(tools.map(\.tool)).count,
              tools == tools.sorted(by: { $0.tool.rawValue < $1.tool.rawValue }),
              commands.count <= ReleaseQualificationLimits.maximumCommandCount else {
            throw ReleaseQualificationContractError.invalid(
                field: "environment",
                reason: "tool or command facts are duplicated, unsorted, or oversized"
            )
        }
        for tool in tools { try tool.validate() }
        for command in commands { try command.validate() }
    }
}

public enum ReleaseQualificationExecutionMode: String, Codable, CaseIterable, Sendable {
    case safeLocal = "safe-local"
    case liveRuntime = "live-runtime"
    case heavy
    case signing
    case externalAuthority = "external-authority"
    case publicAction = "public-action"
}

public enum ReleaseQualificationAuthority: String, Codable, CaseIterable, Sendable {
    case local
    case phase08Runtime = "phase08-runtime"
    case futureProvider = "future-provider"
    case independentAssessor = "independent-assessor"
    case signingIdentity = "signing-identity"
    case publicMaintainer = "public-maintainer"
    case homebrewCore = "homebrew-core"
}

public enum ReleaseQualificationMatrixDimension: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case architecture
    case hardware
    case appleContainer = "apple-container"
    case containerization
    case kubernetes
    case dockerAPI = "docker-api"
    case clientFamily = "client-family"
    case provider
    case plugin
    case packageManager = "package-manager"
    case mdm
    case ide
    case cloud
}

public struct ReleaseQualificationMatrixCell:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let id: String
    public let macOSMajor: Int
    public let architecture: ReleaseQualificationArchitecture
    public let hardware: ReleaseQualificationHardwareCell
    public let provider: ReleaseQualificationProvider
    public let runtimeVersion: ReleaseQualificationSemanticVersion?
    public let frameworkVersion: ReleaseQualificationSemanticVersion?
    public let requiredTools: [ReleaseQualificationTool]
    public let requiredEvidenceClasses: [HostwrightEvidenceClass]
    public let executionMode: ReleaseQualificationExecutionMode
    public let authority: ReleaseQualificationAuthority
    public let claim: String

    public init(
        id: String,
        macOSMajor: Int,
        architecture: ReleaseQualificationArchitecture,
        hardware: ReleaseQualificationHardwareCell,
        provider: ReleaseQualificationProvider,
        runtimeVersion: ReleaseQualificationSemanticVersion?,
        frameworkVersion: ReleaseQualificationSemanticVersion?,
        requiredTools: [ReleaseQualificationTool],
        requiredEvidenceClasses: [HostwrightEvidenceClass],
        executionMode: ReleaseQualificationExecutionMode,
        authority: ReleaseQualificationAuthority,
        claim: String
    ) {
        self.id = id
        self.macOSMajor = macOSMajor
        self.architecture = architecture
        self.hardware = hardware
        self.provider = provider
        self.runtimeVersion = runtimeVersion
        self.frameworkVersion = frameworkVersion
        self.requiredTools = requiredTools.sorted { $0.rawValue < $1.rawValue }
        self.requiredEvidenceClasses = requiredEvidenceClasses.sorted { $0.rawValue < $1.rawValue }
        self.executionMode = executionMode
        self.authority = authority
        self.claim = claim
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              macOSMajor >= 1,
              !requiredTools.isEmpty,
              !requiredEvidenceClasses.isEmpty,
              !claim.isEmpty,
              requiredTools.count == Set(requiredTools).count,
              requiredEvidenceClasses.count == Set(requiredEvidenceClasses).count,
              requiredTools == requiredTools.sorted(by: { $0.rawValue < $1.rawValue }),
              requiredEvidenceClasses == requiredEvidenceClasses.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "matrixCell",
                reason: "cell identity, tools, evidence, or claim is invalid"
            )
        }
        guard provider == .appleContainerCLI
            ? runtimeVersion != nil && frameworkVersion == nil
            : runtimeVersion == nil && frameworkVersion != nil else {
            throw ReleaseQualificationContractError.invalid(
                field: "matrixCell",
                reason: "provider version dimensions do not match the provider"
            )
        }
        switch provider {
        case .appleContainerCLI:
            guard requiredTools == [.appleContainer] else {
                throw ReleaseQualificationContractError.invalid(
                    field: "matrixCell.requiredTools",
                    reason: "Apple container cells require only the Apple container version fact"
                )
            }
        case .appleContainerization:
            guard requiredTools == [.containerizationFramework] else {
                throw ReleaseQualificationContractError.invalid(
                    field: "matrixCell.requiredTools",
                    reason: "Containerization cells require only the pinned framework fact"
                )
            }
        }
    }
}

public struct ReleaseQualificationSupportedMatrix:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let releaseTarget: String
    public let macOSMajors: [Int]
    public let architectures: [ReleaseQualificationArchitecture]
    public let hardwareCells: [ReleaseQualificationHardwareCell]
    public let appleContainerVersions: [ReleaseQualificationSemanticVersion]
    public let containerizationVersions: [ReleaseQualificationSemanticVersion]
    public let kubernetesVersions: [ReleaseQualificationSemanticVersion]
    public let dockerAPIVersions: [ReleaseQualificationSemanticVersion]
    public let clientFamilies: [ReleaseQualificationClientFamily]
    public let providers: [ReleaseQualificationProvider]
    public let cells: [ReleaseQualificationMatrixCell]

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        releaseTarget: String,
        macOSMajors: [Int],
        architectures: [ReleaseQualificationArchitecture],
        hardwareCells: [ReleaseQualificationHardwareCell],
        appleContainerVersions: [ReleaseQualificationSemanticVersion],
        containerizationVersions: [ReleaseQualificationSemanticVersion],
        kubernetesVersions: [ReleaseQualificationSemanticVersion],
        dockerAPIVersions: [ReleaseQualificationSemanticVersion],
        clientFamilies: [ReleaseQualificationClientFamily],
        providers: [ReleaseQualificationProvider],
        cells: [ReleaseQualificationMatrixCell]
    ) {
        self.schemaVersion = schemaVersion
        self.releaseTarget = releaseTarget
        self.macOSMajors = macOSMajors.sorted()
        self.architectures = architectures.sorted { $0.rawValue < $1.rawValue }
        self.hardwareCells = hardwareCells.sorted { $0.rawValue < $1.rawValue }
        self.appleContainerVersions = appleContainerVersions.sorted()
        self.containerizationVersions = containerizationVersions.sorted()
        self.kubernetesVersions = kubernetesVersions.sorted()
        self.dockerAPIVersions = dockerAPIVersions.sorted()
        self.clientFamilies = clientFamilies.sorted { $0.rawValue < $1.rawValue }
        self.providers = providers.sorted { $0.rawValue < $1.rawValue }
        self.cells = cells.sorted { $0.id < $1.id }
    }

    public static let committed = Self(
        releaseTarget: "v0.0.2",
        macOSMajors: [26],
        architectures: [.arm64],
        hardwareCells: [.appleSilicon],
        appleContainerVersions: [
            ReleaseQualificationSemanticVersion(major: 1, minor: 0, patch: 0),
            ReleaseQualificationSemanticVersion(major: 1, minor: 1, patch: 0)
        ],
        containerizationVersions: [
            ReleaseQualificationSemanticVersion(major: 0, minor: 35, patch: 0)
        ],
        kubernetesVersions: [],
        dockerAPIVersions: [],
        clientFamilies: [],
        providers: [.appleContainerCLI, .appleContainerization],
        cells: [
            ReleaseQualificationMatrixCell(
                id: "macos26-arm64-apple-container-1.0.0",
                macOSMajor: 26,
                architecture: .arm64,
                hardware: .appleSilicon,
                provider: .appleContainerCLI,
                runtimeVersion: ReleaseQualificationSemanticVersion(
                    major: 1, minor: 0, patch: 0
                ),
                frameworkVersion: nil,
                requiredTools: [.appleContainer],
                requiredEvidenceClasses: [
                    .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos
                ],
                executionMode: .liveRuntime,
                authority: .phase08Runtime,
                claim: "Apple container 1.0.0 on Apple silicon macOS 26"
            ),
            ReleaseQualificationMatrixCell(
                id: "macos26-arm64-apple-container-1.1.0",
                macOSMajor: 26,
                architecture: .arm64,
                hardware: .appleSilicon,
                provider: .appleContainerCLI,
                runtimeVersion: ReleaseQualificationSemanticVersion(
                    major: 1, minor: 1, patch: 0
                ),
                frameworkVersion: nil,
                requiredTools: [.appleContainer],
                requiredEvidenceClasses: [
                    .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos
                ],
                executionMode: .liveRuntime,
                authority: .phase08Runtime,
                claim: "Apple container 1.1.0 on Apple silicon macOS 26"
            ),
            ReleaseQualificationMatrixCell(
                id: "macos26-arm64-containerization-0.35.0",
                macOSMajor: 26,
                architecture: .arm64,
                hardware: .appleSilicon,
                provider: .appleContainerization,
                runtimeVersion: nil,
                frameworkVersion: ReleaseQualificationSemanticVersion(
                    major: 0, minor: 35, patch: 0
                ),
                requiredTools: [.containerizationFramework],
                requiredEvidenceClasses: [
                    .liveRuntime, .migrationUpgrade, .securityAssessment, .resilienceChaos
                ],
                executionMode: .liveRuntime,
                authority: .phase08Runtime,
                claim: "Containerization 0.35.0 behind the Hostwright helper on Apple silicon macOS 26"
            )
        ]
    )

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
            throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
        }
        guard releaseTarget == "v0.0.2",
              !macOSMajors.isEmpty,
              macOSMajors == Array(Set(macOSMajors)).sorted(),
              architectures == Array(Set(architectures)).sorted(by: { $0.rawValue < $1.rawValue }),
              hardwareCells == Array(Set(hardwareCells)).sorted(by: { $0.rawValue < $1.rawValue }),
              appleContainerVersions == Array(Set(appleContainerVersions)).sorted(),
              containerizationVersions == Array(Set(containerizationVersions)).sorted(),
              kubernetesVersions == Array(Set(kubernetesVersions)).sorted(),
              dockerAPIVersions == Array(Set(dockerAPIVersions)).sorted(),
              clientFamilies == Array(Set(clientFamilies)).sorted(by: { $0.rawValue < $1.rawValue }),
              providers == Array(Set(providers)).sorted(by: { $0.rawValue < $1.rawValue }),
              cells.count <= ReleaseQualificationLimits.maximumMatrixCells,
              cells.map(\.id).count == Set(cells.map(\.id)).count,
              cells == cells.sorted(by: { $0.id < $1.id }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "supportedMatrix",
                reason: "matrix values are duplicated, unsorted, or outside the release contract"
            )
        }
        for cell in cells {
            try cell.validate()
            guard macOSMajors.contains(cell.macOSMajor),
                  architectures.contains(cell.architecture),
                  hardwareCells.contains(cell.hardware),
                  providers.contains(cell.provider) else {
                throw ReleaseQualificationContractError.invalid(
                    field: "supportedMatrix.cells",
                    reason: "cell refers to a dimension absent from the matrix"
                )
            }
            if let runtimeVersion = cell.runtimeVersion {
                guard appleContainerVersions.contains(runtimeVersion) else {
                    throw ReleaseQualificationContractError.invalid(
                        field: "supportedMatrix.cells",
                        reason: "cell refers to an unlisted Apple container version"
                    )
                }
            }
            if let frameworkVersion = cell.frameworkVersion {
                guard containerizationVersions.contains(frameworkVersion) else {
                    throw ReleaseQualificationContractError.invalid(
                        field: "supportedMatrix.cells",
                        reason: "cell refers to an unlisted Containerization version"
                    )
                }
            }
        }
    }

    public func cell(id: String) -> ReleaseQualificationMatrixCell? {
        cells.first { $0.id == id }
    }
}

public enum ReleaseQualificationOutcomeStatus: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case blocked
    case skipped
    case cancelled
    case stale
    case dirty
    case mock
    case fixture
    case unavailable
}

public struct ReleaseQualificationBlocker:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let reason: ReleaseQualificationUnsupportedReason
    public let field: String
    public let detail: String

    public init(
        reason: ReleaseQualificationUnsupportedReason,
        field: String,
        detail: String
    ) {
        self.reason = reason
        self.field = field
        self.detail = detail
    }

    public func validate() throws {
        guard !field.isEmpty,
              field.utf8.count <= 256,
              !detail.isEmpty,
              detail.utf8.count <= 1_024,
              detail.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ReleaseQualificationContractError.invalid(
                field: "blocker",
                reason: "blocker field or detail is invalid"
            )
        }
    }
}

public struct ReleaseQualificationEvaluation:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let cellID: String
    public let status: ReleaseQualificationOutcomeStatus
    public let blockers: [ReleaseQualificationBlocker]
    public let matched: Bool

    public init(
        cellID: String,
        status: ReleaseQualificationOutcomeStatus,
        blockers: [ReleaseQualificationBlocker],
        matched: Bool
    ) {
        self.cellID = cellID
        self.status = status
        self.blockers = blockers
        self.matched = matched
    }

    public func validate() throws {
        guard !cellID.isEmpty,
              blockers.count <= ReleaseQualificationLimits.maximumBlockers,
              Set(blockers).count == blockers.count else {
            throw ReleaseQualificationContractError.invalid(
                field: "evaluation",
                reason: "evaluation identity or blockers are invalid"
            )
        }
        for blocker in blockers { try blocker.validate() }
        if status == .passed {
            guard matched, blockers.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evaluation",
                    reason: "a passing evaluation must match with no blockers"
                )
            }
        }
    }
}

public struct ReleaseQualificationClaim:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let id: String
    public let title: String
    public let matrixCellID: String?
    public let executionMode: ReleaseQualificationExecutionMode
    public let authority: ReleaseQualificationAuthority
    public let requiredEvidenceClasses: [HostwrightEvidenceClass]
    public let requiresCleanSource: Bool
    public let requiresRealEvidence: Bool

    public init(
        id: String,
        title: String,
        matrixCellID: String?,
        executionMode: ReleaseQualificationExecutionMode,
        authority: ReleaseQualificationAuthority,
        requiredEvidenceClasses: [HostwrightEvidenceClass],
        requiresCleanSource: Bool = true,
        requiresRealEvidence: Bool = true
    ) {
        self.id = id
        self.title = title
        self.matrixCellID = matrixCellID
        self.executionMode = executionMode
        self.authority = authority
        self.requiredEvidenceClasses = requiredEvidenceClasses.sorted { $0.rawValue < $1.rawValue }
        self.requiresCleanSource = requiresCleanSource
        self.requiresRealEvidence = requiresRealEvidence
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              !title.isEmpty,
              title.utf8.count <= 1_024,
              title.rangeOfCharacter(from: .controlCharacters) == nil,
              matrixCellID.map({
                  $0.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil
              }) ?? true,
              !requiredEvidenceClasses.isEmpty,
              requiredEvidenceClasses.count == Set(requiredEvidenceClasses).count,
              requiredEvidenceClasses == requiredEvidenceClasses.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "claim",
                reason: "claim identity, title, or evidence requirements are invalid"
            )
        }
    }
}

public enum ReleaseQualificationEvidenceSimulation: String, Codable, Sendable {
    case real
    case mock
    case fixture
}

public enum ReleaseQualificationArtifactRetention: String, Codable, Sendable {
    case retain
    case removeOnCleanup = "remove-on-cleanup"
}

public struct ReleaseQualificationOwnedArtifact:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let relativePath: String
    public let sha256: ReleaseQualificationSHA256
    public let sizeBytes: Int
    public let retention: ReleaseQualificationArtifactRetention
    public let ownershipToken: String

    public init(
        relativePath: String,
        sha256: ReleaseQualificationSHA256,
        sizeBytes: Int,
        retention: ReleaseQualificationArtifactRetention,
        ownershipToken: String
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.retention = retention
        self.ownershipToken = ownershipToken
    }

    public func validate() throws {
        guard ReleaseQualificationPath.isSafeRelative(relativePath),
              sizeBytes >= 0,
              ownershipToken.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try sha256.validate()
    }
}

public struct ReleaseQualificationEvidence:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let runID: String
    public let claim: ReleaseQualificationClaim
    public let evidenceClass: HostwrightEvidenceClass
    public let status: ReleaseQualificationOutcomeStatus
    public let simulation: ReleaseQualificationEvidenceSimulation
    public let source: ReleaseQualificationSourceFacts
    public let environment: ReleaseQualificationDetectedEnvironment
    public let startedAt: ReleaseQualificationTimestamp
    public let endedAt: ReleaseQualificationTimestamp
    public let durationMilliseconds: Int
    public let commands: [ReleaseQualificationCommandObservation]
    public let rawOutputSHA256: [ReleaseQualificationSHA256]
    public let artifacts: [ReleaseQualificationOwnedArtifact]
    public let blockers: [ReleaseQualificationBlocker]
    public let failures: [String]
    public let replayKey: ReleaseQualificationSHA256

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        runID: String,
        claim: ReleaseQualificationClaim,
        evidenceClass: HostwrightEvidenceClass,
        status: ReleaseQualificationOutcomeStatus,
        simulation: ReleaseQualificationEvidenceSimulation,
        source: ReleaseQualificationSourceFacts,
        environment: ReleaseQualificationDetectedEnvironment,
        startedAt: ReleaseQualificationTimestamp,
        endedAt: ReleaseQualificationTimestamp,
        durationMilliseconds: Int,
        commands: [ReleaseQualificationCommandObservation],
        rawOutputSHA256: [ReleaseQualificationSHA256],
        artifacts: [ReleaseQualificationOwnedArtifact],
        blockers: [ReleaseQualificationBlocker],
        failures: [String],
        replayKey: ReleaseQualificationSHA256
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.claim = claim
        self.evidenceClass = evidenceClass
        self.status = status
        self.simulation = simulation
        self.source = source
        self.environment = environment
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.commands = commands
        self.rawOutputSHA256 = Array(Set(rawOutputSHA256)).sorted { $0.value < $1.value }
        self.artifacts = artifacts.sorted { $0.relativePath < $1.relativePath }
        self.blockers = blockers
        self.failures = failures
        self.replayKey = replayKey
    }

    public var satisfiesRequiredGate: Bool {
        status == .passed &&
            simulation == .real &&
            claim.requiredEvidenceClasses.contains(evidenceClass) &&
            source.availability.status == .available &&
            source.dirty == false &&
            blockers.isEmpty &&
            failures.isEmpty
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              runID.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              durationMilliseconds >= 0,
              !commands.isEmpty,
              commands.count <= ReleaseQualificationLimits.maximumCommandCount,
              artifacts.count <= ReleaseQualificationLimits.maximumArtifacts,
              blockers.count <= ReleaseQualificationLimits.maximumBlockers,
              Set(rawOutputSHA256).count == rawOutputSHA256.count,
              rawOutputSHA256 == rawOutputSHA256.sorted(by: { $0.value < $1.value }),
              artifacts == artifacts.sorted(by: { $0.relativePath < $1.relativePath }),
              blockers == blockers.sorted(by: {
                  ($0.field, $0.reason.rawValue, $0.detail) <
                      ($1.field, $1.reason.rawValue, $1.detail)
              }),
              failures == failures.sorted(),
              Set(artifacts.map(\.relativePath)).count == artifacts.count else {
            throw ReleaseQualificationContractError.invalid(
                field: "evidence",
                reason: "evidence bounds, ordering, or identity is invalid"
            )
        }
        try claim.validate()
        guard claim.requiredEvidenceClasses.contains(evidenceClass) else {
            throw ReleaseQualificationContractError.invalid(
                field: "evidence.evidenceClass",
                reason: "evidence class is not required by the bound claim"
            )
        }
        try source.validate()
        try environment.validate()
        try startedAt.validate()
        try endedAt.validate()
        try replayKey.validate()
        for command in commands { try command.validate() }
        for artifact in artifacts { try artifact.validate() }
        for blocker in blockers { try blocker.validate() }
        for hash in rawOutputSHA256 { try hash.validate() }
        guard failures.allSatisfy({
            !$0.isEmpty &&
                $0.utf8.count <= 1_024 &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil
        }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "evidence.failures",
                reason: "failure detail is invalid"
            )
        }
        let commandOutputHashes =
            commands.map({ $0.standardOutputSHA256 }) + commands.map({ $0.standardErrorSHA256 })
        guard commandOutputHashes.allSatisfy({ rawOutputSHA256.contains($0) }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "evidence.rawOutputSHA256",
                reason: "every command output hash must be bound to the evidence"
            )
        }
        guard source == environment.source else {
            throw ReleaseQualificationContractError.invalid(
                field: "evidence.source",
                reason: "evidence source facts do not match the detected environment"
            )
        }
        if status == .passed {
            guard satisfiesRequiredGate else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evidence.status",
                    reason: "passing evidence is not clean, real, and blocker-free"
                )
            }
        }
        if status == .failed {
            guard !failures.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evidence.failures",
                    reason: "failed evidence requires a failure"
                )
            }
        }
        if [.blocked, .unavailable, .stale, .dirty, .mock, .fixture].contains(status) {
            guard !blockers.isEmpty || status == .dirty || status == .mock || status == .fixture else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evidence.blockers",
                    reason: "non-passing evidence requires an explicit blocker"
                )
            }
        }
        if [.skipped, .cancelled].contains(status) {
            guard !blockers.isEmpty else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evidence.blockers",
                    reason: "skipped or cancelled evidence requires an explicit blocker"
                )
            }
        }
    }
}

public enum ReleaseQualificationLaneKind: String, Codable, CaseIterable, Sendable {
    case parserFuzz = "parser-fuzz"
    case protocolFuzz = "protocol-fuzz"
    case sanitizer
    case dependency
    case sast
    case secret
    case license
    case sbom
    case provenance
    case signing
    case performance
    case disasterRecovery = "disaster-recovery"
    case upgradeLineage = "upgrade-lineage"
    case distribution
    case publicSubmission = "public-submission"
}

public struct ReleaseQualificationBudget:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let maximumDurationSeconds: Int
    public let maximumCPUHours: Int
    public let maximumInputBytes: Int
    public let maximumOutputBytes: Int

    public init(
        maximumDurationSeconds: Int,
        maximumCPUHours: Int,
        maximumInputBytes: Int,
        maximumOutputBytes: Int
    ) {
        self.maximumDurationSeconds = maximumDurationSeconds
        self.maximumCPUHours = maximumCPUHours
        self.maximumInputBytes = maximumInputBytes
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func validate() throws {
        guard (1...31_536_000).contains(maximumDurationSeconds),
              (0...10_000).contains(maximumCPUHours),
              (0...1_073_741_824).contains(maximumInputBytes),
              (1...1_073_741_824).contains(maximumOutputBytes) else {
            throw ReleaseQualificationContractError.invalid(
                field: "budget",
                reason: "budget exceeds a safe bound"
            )
        }
    }
}

public enum ReleaseQualificationCorpusExpectation: String, Codable, Sendable {
    case accept
    case reject
}

public struct ReleaseQualificationCorpusIdentity:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let id: String
    public let relativePath: String
    public let sha256: ReleaseQualificationSHA256
    public let sizeBytes: Int
    public let expectation: ReleaseQualificationCorpusExpectation

    public init(
        id: String,
        relativePath: String,
        sha256: ReleaseQualificationSHA256,
        sizeBytes: Int,
        expectation: ReleaseQualificationCorpusExpectation
    ) {
        self.id = id
        self.relativePath = relativePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.expectation = expectation
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              ReleaseQualificationPath.isSafeRelative(relativePath),
              sizeBytes >= 0 else {
            throw ReleaseQualificationContractError.invalid(
                field: "corpusIdentity",
                reason: "corpus identity or path is invalid"
            )
        }
        try sha256.validate()
    }
}

public struct ReleaseQualificationLane:
    Codable, Equatable, Hashable, Sendable, ReleaseQualificationValidating
{
    public let id: String
    public let kind: ReleaseQualificationLaneKind
    public let target: String
    public let executionMode: ReleaseQualificationExecutionMode
    public let authority: ReleaseQualificationAuthority
    public let requiredEvidenceClasses: [HostwrightEvidenceClass]
    public let budget: ReleaseQualificationBudget
    public let corpus: [ReleaseQualificationCorpusIdentity]
    public let exclusions: [String]

    public init(
        id: String,
        kind: ReleaseQualificationLaneKind,
        target: String,
        executionMode: ReleaseQualificationExecutionMode,
        authority: ReleaseQualificationAuthority,
        requiredEvidenceClasses: [HostwrightEvidenceClass],
        budget: ReleaseQualificationBudget,
        corpus: [ReleaseQualificationCorpusIdentity],
        exclusions: [String]
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.executionMode = executionMode
        self.authority = authority
        self.requiredEvidenceClasses = requiredEvidenceClasses.sorted { $0.rawValue < $1.rawValue }
        self.budget = budget
        self.corpus = corpus.sorted { $0.id < $1.id }
        self.exclusions = exclusions.sorted()
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil,
              !target.isEmpty,
              !requiredEvidenceClasses.isEmpty,
              !corpus.isEmpty || kind == .protocolFuzz || kind == .sanitizer || kind == .dependency || kind == .sast ||
                  kind == .secret || kind == .license,
              requiredEvidenceClasses.count == Set(requiredEvidenceClasses).count,
              corpus.map(\.id).count == Set(corpus.map(\.id)).count,
              exclusions.allSatisfy({ !$0.isEmpty }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "lane",
                reason: "lane identity, target, evidence, or corpus is invalid"
            )
        }
        try budget.validate()
        for item in corpus { try item.validate() }
    }
}

public enum ReleaseQualificationLanePlanStatus: String, Codable, Sendable {
    case ready
    case blocked
    case unavailable
}

public struct ReleaseQualificationLanePlan:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let laneID: String
    public let status: ReleaseQualificationLanePlanStatus
    public let blockers: [ReleaseQualificationBlocker]
    public let observedCorpus: [ReleaseQualificationCorpusIdentity]

    public init(
        laneID: String,
        status: ReleaseQualificationLanePlanStatus,
        blockers: [ReleaseQualificationBlocker],
        observedCorpus: [ReleaseQualificationCorpusIdentity]
    ) {
        self.laneID = laneID
        self.status = status
        self.blockers = blockers
        self.observedCorpus = observedCorpus.sorted { $0.id < $1.id }
    }

    public func validate() throws {
        guard !laneID.isEmpty,
              blockers.count <= ReleaseQualificationLimits.maximumBlockers,
              Set(blockers).count == blockers.count else {
            throw ReleaseQualificationContractError.invalid(
                field: "lanePlan",
                reason: "lane plan identity or blockers are invalid"
            )
        }
        for blocker in blockers { try blocker.validate() }
        for corpus in observedCorpus { try corpus.validate() }
    }
}

public struct ReleaseQualificationRegistry:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let lanes: [ReleaseQualificationLane]

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        lanes: [ReleaseQualificationLane]
    ) {
        self.schemaVersion = schemaVersion
        self.lanes = lanes.sorted { $0.id < $1.id }
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              !lanes.isEmpty,
              lanes.map(\.id).count == Set(lanes.map(\.id)).count,
              lanes == lanes.sorted(by: { $0.id < $1.id }) else {
            throw ReleaseQualificationContractError.invalid(
                field: "registry",
                reason: "registry version, identity, or ordering is invalid"
            )
        }
        for lane in lanes { try lane.validate() }
    }
}

public struct ReleaseQualificationPlanDocument:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let kind: String
    public let matrix: ReleaseQualificationSupportedMatrix
    public let registry: ReleaseQualificationRegistry
    public let lanes: [ReleaseQualificationLanePlan]

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        matrix: ReleaseQualificationSupportedMatrix,
        registry: ReleaseQualificationRegistry,
        lanes: [ReleaseQualificationLanePlan]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "hostwright.release-qualification.plan.v1"
        self.matrix = matrix
        self.registry = registry
        self.lanes = lanes.sorted { $0.laneID < $1.laneID }
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              kind == "hostwright.release-qualification.plan.v1" else {
            throw ReleaseQualificationContractError.schemaMismatch
        }
        try matrix.validate()
        try registry.validate()
        guard lanes.count == registry.lanes.count,
              lanes.map(\.laneID) == registry.lanes.map(\.id) else {
            throw ReleaseQualificationContractError.invalid(
                field: "plan.lanes",
                reason: "lane plans do not cover the registry exactly"
            )
        }
        for lane in lanes { try lane.validate() }
    }
}

public struct ReleaseQualificationDetectionDocument:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let kind: String
    public let environment: ReleaseQualificationDetectedEnvironment
    public let evaluations: [ReleaseQualificationEvaluation]

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        environment: ReleaseQualificationDetectedEnvironment,
        evaluations: [ReleaseQualificationEvaluation]
    ) {
        self.schemaVersion = schemaVersion
        self.kind = "hostwright.release-qualification.detect.v1"
        self.environment = environment
        self.evaluations = evaluations.sorted { $0.cellID < $1.cellID }
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              kind == "hostwright.release-qualification.detect.v1",
              evaluations.map(\.cellID).count == Set(evaluations.map(\.cellID)).count else {
            throw ReleaseQualificationContractError.schemaMismatch
        }
        try environment.validate()
        for evaluation in evaluations { try evaluation.validate() }
    }
}

public enum ReleaseQualificationJournalState: String, Codable, Sendable {
    case running
    case interrupted
    case completed
    case cancelled
}

public struct ReleaseQualificationJournal:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let runID: String
    public let state: ReleaseQualificationJournalState
    public let claim: ReleaseQualificationClaim
    public let replayKey: ReleaseQualificationSHA256
    public let createdAt: ReleaseQualificationTimestamp
    public let updatedAt: ReleaseQualificationTimestamp
    public let evidence: ReleaseQualificationEvidence?

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        runID: String,
        state: ReleaseQualificationJournalState,
        claim: ReleaseQualificationClaim,
        replayKey: ReleaseQualificationSHA256,
        createdAt: ReleaseQualificationTimestamp,
        updatedAt: ReleaseQualificationTimestamp,
        evidence: ReleaseQualificationEvidence?
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.state = state
        self.claim = claim
        self.replayKey = replayKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.evidence = evidence
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              !runID.isEmpty else {
            throw ReleaseQualificationContractError.invalid(
                field: "journal",
                reason: "journal identity or schema is invalid"
            )
        }
        try claim.validate()
        try replayKey.validate()
        try createdAt.validate()
        try updatedAt.validate()
        if let evidence { try evidence.validate() }
        switch state {
        case .running, .interrupted:
            guard evidence == nil else {
                throw ReleaseQualificationContractError.invalid(
                    field: "journal",
                    reason: "unfinished journal may not carry final evidence"
                )
            }
        case .completed, .cancelled:
            if state == .completed {
                guard evidence != nil else {
                    throw ReleaseQualificationContractError.invalid(
                        field: "journal",
                        reason: "completed journal requires final evidence"
                    )
                }
            }
        }
    }
}

public struct ReleaseQualificationLedgerSummary:
    Codable, Equatable, Sendable, ReleaseQualificationValidating
{
    public let schemaVersion: Int
    public let running: Int
    public let interrupted: Int
    public let completed: Int
    public let cancelled: Int
    public let satisfyingGates: Int

    public init(
        schemaVersion: Int = ReleaseQualificationLimits.schemaVersion,
        running: Int,
        interrupted: Int,
        completed: Int,
        cancelled: Int,
        satisfyingGates: Int
    ) {
        self.schemaVersion = schemaVersion
        self.running = running
        self.interrupted = interrupted
        self.completed = completed
        self.cancelled = cancelled
        self.satisfyingGates = satisfyingGates
    }

    public func validate() throws {
        guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
              [running, interrupted, completed, cancelled, satisfyingGates].allSatisfy({ $0 >= 0 }),
              satisfyingGates <= completed else {
            throw ReleaseQualificationContractError.invalid(
                field: "ledgerSummary",
                reason: "summary counts are invalid"
            )
        }
    }
}

public enum ReleaseQualificationPath {
    public static func isNormalizedAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= 4_096,
              path == NSString(string: path).standardizingPath,
              !path.hasSuffix("/"),
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return path == "/"
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func isSafeRelative(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              path.utf8.count <= 4_096,
              path == NSString(string: path).standardizingPath,
              path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    public static func isContained(_ path: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let pathValue = path.standardizedFileURL.path
        return pathValue == rootPath || pathValue.hasPrefix(rootPath + "/")
    }
}
