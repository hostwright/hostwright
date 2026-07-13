import Foundation

public enum HostwrightEvidenceClass: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case unitContract = "unit-contract"
    case localIntegration = "local-integration"
    case liveRuntime = "live-runtime"
    case hardwareBenchmark = "hardware-benchmark"
    case distributionArtifact = "distribution-artifact"
    case migrationUpgrade = "migration-upgrade"
    case securityAssessment = "security-assessment"
    case resilienceChaos = "resilience-chaos"
    case multiHost = "multi-host"
    case interopConformance = "interop-conformance"
    case uxAccessibility = "ux-accessibility"
}

public enum HostwrightEvidenceStatus: String, Codable, Equatable, Sendable {
    case passed
    case failed
    case blocked
}

public struct HostwrightEvidenceSource: Codable, Equatable, Sendable {
    public let commit: String
    public let dirty: Bool

    public init(commit: String, dirty: Bool) {
        self.commit = commit
        self.dirty = dirty
    }
}

public struct HostwrightEvidenceEnvironment: Codable, Equatable, Sendable {
    public let operatingSystem: String
    public let build: String
    public let architecture: String
    public let hardwareModel: String
    public let memoryBytes: Int
    public let toolVersions: [String: String]

    public init(
        operatingSystem: String,
        build: String,
        architecture: String,
        hardwareModel: String,
        memoryBytes: Int,
        toolVersions: [String: String]
    ) {
        self.operatingSystem = operatingSystem
        self.build = build
        self.architecture = architecture
        self.hardwareModel = hardwareModel
        self.memoryBytes = memoryBytes
        self.toolVersions = toolVersions
    }
}

public struct HostwrightEvidenceCommand: Codable, Equatable, Sendable {
    public let command: String
    public let exitCode: Int
    public let durationMilliseconds: Int

    public init(command: String, exitCode: Int, durationMilliseconds: Int) {
        self.command = command
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct HostwrightEvidenceCounts: Codable, Equatable, Sendable {
    public let executed: Int
    public let passed: Int
    public let failed: Int
    public let blocked: Int

    public init(executed: Int, passed: Int, failed: Int, blocked: Int) {
        self.executed = executed
        self.passed = passed
        self.failed = failed
        self.blocked = blocked
    }
}

public enum HostwrightEvidenceCleanupStatus: String, Codable, Equatable, Sendable {
    case notRequired = "not-required"
    case succeeded
    case failed
}

public struct HostwrightEvidenceCleanup: Codable, Equatable, Sendable {
    public let status: HostwrightEvidenceCleanupStatus
    public let exactResourceIdentifiers: [String]
    public let message: String?

    public init(
        status: HostwrightEvidenceCleanupStatus,
        exactResourceIdentifiers: [String],
        message: String? = nil
    ) {
        self.status = status
        self.exactResourceIdentifiers = exactResourceIdentifiers
        self.message = message
    }
}

public struct HostwrightEvidenceReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidenceClass: HostwrightEvidenceClass
    public let status: HostwrightEvidenceStatus
    public let recordedAt: String
    public let source: HostwrightEvidenceSource
    public let environment: HostwrightEvidenceEnvironment
    public let commands: [HostwrightEvidenceCommand]
    public let rawResults: HostwrightEvidenceCounts
    public let failures: [String]
    public let blockers: [String]
    public let cleanup: HostwrightEvidenceCleanup

    public init(
        schemaVersion: Int = 1,
        evidenceClass: HostwrightEvidenceClass,
        status: HostwrightEvidenceStatus,
        recordedAt: String,
        source: HostwrightEvidenceSource,
        environment: HostwrightEvidenceEnvironment,
        commands: [HostwrightEvidenceCommand],
        rawResults: HostwrightEvidenceCounts,
        failures: [String],
        blockers: [String],
        cleanup: HostwrightEvidenceCleanup
    ) {
        self.schemaVersion = schemaVersion
        self.evidenceClass = evidenceClass
        self.status = status
        self.recordedAt = recordedAt
        self.source = source
        self.environment = environment
        self.commands = commands
        self.rawResults = rawResults
        self.failures = failures
        self.blockers = blockers
        self.cleanup = cleanup
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw HostwrightEvidenceValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard source.commit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              source.commit != String(repeating: "0", count: 40) else {
            throw HostwrightEvidenceValidationError.invalidSourceCommit
        }
        guard ISO8601DateFormatter().date(from: recordedAt) != nil,
              !environment.operatingSystem.isEmpty,
              !environment.build.isEmpty,
              !environment.architecture.isEmpty,
              !environment.hardwareModel.isEmpty,
              environment.memoryBytes > 0,
              !commands.isEmpty else {
            throw HostwrightEvidenceValidationError.missingRequiredEvidence
        }
        guard commands.allSatisfy({ !$0.command.isEmpty && $0.durationMilliseconds >= 0 }),
              rawResults.executed >= 0,
              rawResults.passed >= 0,
              rawResults.failed >= 0,
              rawResults.blocked >= 0,
              rawResults.executed == rawResults.passed + rawResults.failed + rawResults.blocked else {
            throw HostwrightEvidenceValidationError.invalidResultCounts
        }
        guard Set(cleanup.exactResourceIdentifiers).count == cleanup.exactResourceIdentifiers.count,
              cleanup.exactResourceIdentifiers.allSatisfy({ !$0.isEmpty }) else {
            throw HostwrightEvidenceValidationError.invalidCleanup
        }

        switch status {
        case .passed:
            guard commands.allSatisfy({ $0.exitCode == 0 }),
                  rawResults.executed > 0,
                  rawResults.passed > 0,
                  rawResults.failed == 0,
                  rawResults.blocked == 0,
                  failures.isEmpty,
                  blockers.isEmpty,
                  cleanup.status != .failed else {
                throw HostwrightEvidenceValidationError.invalidPassingEvidence
            }
        case .failed:
            guard !failures.isEmpty else {
                throw HostwrightEvidenceValidationError.missingFailure
            }
        case .blocked:
            guard !blockers.isEmpty else {
                throw HostwrightEvidenceValidationError.missingBlocker
            }
        }

        let exactCleanupEvidence: Set<HostwrightEvidenceClass> = [
            .liveRuntime,
            .hardwareBenchmark,
            .resilienceChaos,
            .multiHost,
            .interopConformance
        ]
        if exactCleanupEvidence.contains(evidenceClass) {
            guard status != .passed ||
                    (cleanup.status == .succeeded && !cleanup.exactResourceIdentifiers.isEmpty) else {
                throw HostwrightEvidenceValidationError.invalidCleanup
            }
        }
    }
}

public enum HostwrightEvidenceValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidSourceCommit
    case missingRequiredEvidence
    case invalidResultCounts
    case invalidCleanup
    case invalidPassingEvidence
    case missingFailure
    case missingBlocker
}
