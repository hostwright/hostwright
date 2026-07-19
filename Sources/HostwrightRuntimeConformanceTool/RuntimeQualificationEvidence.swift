import Darwin
import Foundation
import HostwrightRuntime

struct RuntimeQualificationSubject: Codable, Equatable, Sendable {
    let providerID: String
    let providerVersion: String
}

struct RuntimeQualificationFixtureImage: Codable, Equatable, Sendable {
    let reference: String
    let digest: String
}

struct RuntimeQualificationInventoryEvidence: Codable, Equatable, Sendable {
    let beforeSHA256: String
    let afterSHA256: String
    let unmanagedBeforeSHA256: String
    let unmanagedAfterSHA256: String
}

struct RuntimeQualificationSummary: Codable, Equatable, Sendable {
    let passed: Int
    let failed: Int
}

struct RuntimeQualificationCommandEvidence: Codable, Equatable, Hashable, Sendable {
    let arguments: [String]
    let exitStatus: Int
}

struct RuntimeQualificationCleanupEvidence: Codable, Equatable, Sendable {
    let complete: Bool
    let identifiers: [String]
}

struct RuntimeQualificationConformanceDetails: Codable, Equatable, Sendable {
    let capabilitySHA256: String
    let conformance: RuntimeProviderLiveQualificationEvidence
    let imageVariantDigest: String
    let runtimeVersion: String
}

struct RuntimeQualificationConformanceReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let status: String
    let subjects: [RuntimeQualificationSubject]
    let fixtureImage: RuntimeQualificationFixtureImage
    let inventory: RuntimeQualificationInventoryEvidence
    let unmanagedInventoryUnchanged: Bool
    let summary: RuntimeQualificationSummary
    let commands: [RuntimeQualificationCommandEvidence]
    let cleanup: RuntimeQualificationCleanupEvidence
    let details: RuntimeQualificationConformanceDetails
}

struct RuntimeQualificationMigrationDetails: Codable, Equatable, Sendable {
    let migration: RuntimeQualificationMigrationEvidence
}

struct RuntimeQualificationMigrationReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let status: String
    let subjects: [RuntimeQualificationSubject]
    let fixtureImage: RuntimeQualificationFixtureImage
    let inventory: RuntimeQualificationInventoryEvidence
    let unmanagedInventoryUnchanged: Bool
    let summary: RuntimeQualificationSummary
    let commands: [RuntimeQualificationCommandEvidence]
    let cleanup: RuntimeQualificationCleanupEvidence
    let details: RuntimeQualificationMigrationDetails
}

enum RuntimeQualificationEvidenceError: Error, Equatable {
    case invalidEvidence
    case oversizedEvidence
    case outputUnavailable
    case outputWriteFailed
}

actor RuntimeQualificationCommandRecorder {
    private static let maximumRecords = 256
    private var records: [RuntimeQualificationCommandEvidence] = []
    private var uniqueRecords: Set<RuntimeQualificationCommandEvidence> = []
    private var overflowed = false

    func record(arguments: [String], exitStatus: Int) {
        guard let executable = arguments.first,
              arguments.count <= 128,
              arguments.allSatisfy({ Self.valid($0) }),
              (-1...255).contains(exitStatus) else {
            overflowed = true
            return
        }
        let normalized = [URL(fileURLWithPath: executable).lastPathComponent]
            + Array(arguments.dropFirst())
        let record = RuntimeQualificationCommandEvidence(
            arguments: normalized,
            exitStatus: exitStatus
        )
        guard uniqueRecords.insert(record).inserted else { return }
        guard records.count < Self.maximumRecords else {
            overflowed = true
            return
        }
        records.append(record)
    }

    func evidence() throws -> [RuntimeQualificationCommandEvidence] {
        guard !overflowed, !records.isEmpty else {
            throw RuntimeQualificationEvidenceError.invalidEvidence
        }
        return records
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 4_096 &&
            value.rangeOfCharacter(from: .controlCharacters) == nil &&
            value.range(
                of: #"(?i)(password|secret|credential|authorization|cookie|private.?key|api.?key|bearer|access.?token|refresh.?token|session.?token|confirmation.?token)"#,
                options: .regularExpression
            ) == nil
    }
}

enum RuntimeQualificationEvidenceWriter {
    static let maximumBytes = 8 * 1_024 * 1_024

    static func write<Report: Encodable>(_ report: Report, to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0a)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RuntimeQualificationEvidenceError.oversizedEvidence
        }

        let descriptor = Darwin.open(
            outputURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RuntimeQualificationEvidenceError.outputUnavailable
        }
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete { _ = Darwin.unlink(outputURL.path) }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw RuntimeQualificationEvidenceError.outputWriteFailed
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else {
                    throw RuntimeQualificationEvidenceError.outputWriteFailed
                }
                offset += amount
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RuntimeQualificationEvidenceError.outputWriteFailed
        }
        let parent = Darwin.open(
            outputURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard parent >= 0 else {
            throw RuntimeQualificationEvidenceError.outputWriteFailed
        }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else {
            throw RuntimeQualificationEvidenceError.outputWriteFailed
        }
        complete = true
    }
}
