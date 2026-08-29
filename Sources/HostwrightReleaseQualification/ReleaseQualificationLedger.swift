import Darwin
import Foundation
import HostwrightCore

public enum ReleaseQualificationLedgerAction: String, Codable, Sendable {
    case created
    case replayed
    case recovered
}

public struct ReleaseQualificationLedgerStore: @unchecked Sendable {
    private let root: URL
    private let journalsDirectory: URL
    private let artifactsDirectory: URL
    private let lock = NSLock()

    public init(root: URL, createIfMissing: Bool = true) throws {
        guard ReleaseQualificationPath.isNormalizedAbsolute(root.path),
              root.path != "/" else {
            throw ReleaseQualificationContractError.unsafePath
        }
        self.root = root
        journalsDirectory = root.appendingPathComponent("journals", isDirectory: true)
        artifactsDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        try Self.prepareRoot(root, createIfMissing: createIfMissing)
        try Self.prepareChild(journalsDirectory)
        try Self.prepareChild(artifactsDirectory)
        try Self.prepareChild(root.appendingPathComponent("tmp", isDirectory: true))
        try ensureOwner()
    }

    public var path: URL { root }

    public func begin(
        runID: String,
        claim: ReleaseQualificationClaim,
        replayKey: ReleaseQualificationSHA256,
        at timestamp: ReleaseQualificationTimestamp = ReleaseQualificationTimestamp(),
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationLedgerAction {
        try withLock {
            try checkCancellation(cancellation)
            try validateRunID(runID)
            try claim.validate()
            try replayKey.validate()
            let url = journalURL(runID: runID)
            if let existing = try readJournalIfPresent(at: url) {
                guard existing.replayKey == replayKey, existing.claim == claim else {
                    throw ReleaseQualificationContractError.ledgerConflict
                }
                switch existing.state {
                case .completed, .cancelled, .running:
                    return .replayed
                case .interrupted:
                    let resumed = ReleaseQualificationJournal(
                        runID: runID,
                        state: .running,
                        claim: claim,
                        replayKey: replayKey,
                        createdAt: existing.createdAt,
                        updatedAt: timestamp,
                        evidence: nil
                    )
                    try writeJournal(resumed, to: url)
                    return .recovered
                }
            }
            let journal = ReleaseQualificationJournal(
                runID: runID,
                state: .running,
                claim: claim,
                replayKey: replayKey,
                createdAt: timestamp,
                updatedAt: timestamp,
                evidence: nil
            )
            try writeJournal(journal, to: url)
            return .created
        }
    }

    public func complete(
        runID: String,
        evidence: ReleaseQualificationEvidence,
        at timestamp: ReleaseQualificationTimestamp = ReleaseQualificationTimestamp(),
        cancellation: SecureSubprocessCancellation = SecureSubprocessCancellation()
    ) throws -> ReleaseQualificationLedgerAction {
        try withLock {
            try checkCancellation(cancellation)
            try validateRunID(runID)
            try evidence.validate()
            guard evidence.runID == runID else {
                throw ReleaseQualificationContractError.invalid(
                    field: "evidence.runID",
                    reason: "evidence does not match the journal identity"
                )
            }
            let url = journalURL(runID: runID)
            guard let existing = try readJournalIfPresent(at: url) else {
                throw ReleaseQualificationContractError.invalid(
                    field: "journal",
                    reason: "run was not prepared before completion"
                )
            }
            guard existing.claim == evidence.claim,
                  existing.replayKey == evidence.replayKey else {
                throw ReleaseQualificationContractError.ledgerConflict
            }
            if existing.state == .completed, let prior = existing.evidence {
                guard prior == evidence else {
                    throw ReleaseQualificationContractError.ledgerConflict
                }
                return .replayed
            }
            guard existing.state == .running || existing.state == .interrupted else {
                throw ReleaseQualificationContractError.ledgerConflict
            }
            let completed = ReleaseQualificationJournal(
                runID: runID,
                state: .completed,
                claim: existing.claim,
                replayKey: existing.replayKey,
                createdAt: existing.createdAt,
                updatedAt: timestamp,
                evidence: evidence
            )
            try writeJournal(completed, to: url)
            return .created
        }
    }

    public func cancel(
        runID: String,
        at timestamp: ReleaseQualificationTimestamp = ReleaseQualificationTimestamp()
    ) throws {
        try withLock {
            try validateRunID(runID)
            let url = journalURL(runID: runID)
            guard let existing = try readJournalIfPresent(at: url),
                  existing.state == .running || existing.state == .interrupted else {
                throw ReleaseQualificationContractError.ledgerConflict
            }
            let cancelled = ReleaseQualificationJournal(
                runID: runID,
                state: .cancelled,
                claim: existing.claim,
                replayKey: existing.replayKey,
                createdAt: existing.createdAt,
                updatedAt: timestamp,
                evidence: nil
            )
            try writeJournal(cancelled, to: url)
        }
    }

    public func recover(
        at timestamp: ReleaseQualificationTimestamp = ReleaseQualificationTimestamp()
    ) throws -> [String] {
        try withLock {
            let journals = try readJournals()
            var recovered: [String] = []
            for journal in journals where journal.state == .running {
                let interrupted = ReleaseQualificationJournal(
                    runID: journal.runID,
                    state: .interrupted,
                    claim: journal.claim,
                    replayKey: journal.replayKey,
                    createdAt: journal.createdAt,
                    updatedAt: timestamp,
                    evidence: nil
                )
                try writeJournal(interrupted, to: journalURL(runID: journal.runID))
                recovered.append(journal.runID)
            }
            return recovered.sorted()
        }
    }

    public func journal(runID: String) throws -> ReleaseQualificationJournal {
        try withLock {
            try validateRunID(runID)
            guard let journal = try readJournalIfPresent(at: journalURL(runID: runID)) else {
                throw ReleaseQualificationContractError.invalid(
                    field: "runID",
                    reason: "run is not present in the private ledger"
                )
            }
            return journal
        }
    }

    public func journals() throws -> [ReleaseQualificationJournal] {
        try withLock { try readJournals() }
    }

    public func summary() throws -> ReleaseQualificationLedgerSummary {
        try withLock {
            let journals = try readJournals()
            return ReleaseQualificationLedgerSummary(
                running: journals.filter { $0.state == .running }.count,
                interrupted: journals.filter { $0.state == .interrupted }.count,
                completed: journals.filter { $0.state == .completed }.count,
                cancelled: journals.filter { $0.state == .cancelled }.count,
                satisfyingGates: journals.compactMap(\.evidence).filter(\.satisfiesRequiredGate).count
            )
        }
    }

    public func verifyCurrent(
        runID: String,
        environment: ReleaseQualificationDetectedEnvironment
    ) throws -> ReleaseQualificationEvidence {
        try withLock {
            let journal = try readRequiredJournal(runID: runID)
            guard journal.state == .completed, let evidence = journal.evidence else {
                throw ReleaseQualificationContractError.staleEvidence
            }
            try evidence.validate()
            guard evidence.source == environment.source,
                  evidence.environment.fingerprint == environment.fingerprint else {
                throw ReleaseQualificationContractError.staleEvidence
            }
            return evidence
        }
    }

    public func publishArtifact(
        data: Data,
        relativePath: String,
        retention: ReleaseQualificationArtifactRetention = .retain
    ) throws -> ReleaseQualificationOwnedArtifact {
        try withLock {
            guard ReleaseQualificationPath.isSafeRelative(relativePath),
                  !relativePath.hasPrefix("journals/"),
                  !relativePath.hasPrefix("tmp/"),
                  data.count <= ReleaseQualificationLimits.maximumSourceFileBytes else {
                throw ReleaseQualificationContractError.unsafePath
            }
            let target = artifactsDirectory.appendingPathComponent(relativePath)
            try prepareArtifactParent(target.deletingLastPathComponent())
            let token = String(
                UUID().uuidString.filter { $0 != "-" }.prefix(32)
            ).lowercased()
            let marker = target.deletingLastPathComponent().appendingPathComponent(
                ".hostwright-owner-\(token)"
            )
            try ReleaseQualificationFile.writeAtomically(
                data: data,
                to: target,
                mode: 0o600,
                createParent: false
            )
            do {
                try ReleaseQualificationFile.writeAtomically(
                    data: Data(token.utf8),
                    to: marker,
                    mode: 0o600,
                    createParent: false
                )
            } catch {
                _ = Darwin.unlink(target.path)
                throw error
            }
            return ReleaseQualificationOwnedArtifact(
                relativePath: relativePath,
                sha256: ReleaseQualificationHash.sha256(data: data),
                sizeBytes: data.count,
                retention: retention,
                ownershipToken: token
            )
        }
    }

    public func cleanup(runID: String) throws -> [String] {
        try withLock {
            let journal = try readRequiredJournal(runID: runID)
            guard let evidence = journal.evidence else { return [] }
            let removable = evidence.artifacts.filter {
                $0.retention == .removeOnCleanup
            }
            var targets: [(URL, URL)] = []
            for artifact in removable {
                guard ReleaseQualificationPath.isSafeRelative(artifact.relativePath) else {
                    throw ReleaseQualificationContractError.unsafePath
                }
                let target = artifactsDirectory.appendingPathComponent(artifact.relativePath)
                let marker = target.deletingLastPathComponent().appendingPathComponent(
                    ".hostwright-owner-\(artifact.ownershipToken)"
                )
                try validateArtifactParent(target.deletingLastPathComponent())
                guard try ReleaseQualificationFile.isRegularNonSymlink(target),
                      try ReleaseQualificationFile.isRegularNonSymlink(marker),
                      try Data(contentsOf: marker) == Data(artifact.ownershipToken.utf8),
                      try ReleaseQualificationHash.sha256(fileURL: target) == artifact.sha256 else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                guard let size = (attributes[.size] as? NSNumber)?.intValue,
                      size == artifact.sizeBytes else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                targets.append((target, marker))
            }
            for (target, marker) in targets {
                guard Darwin.unlink(target.path) == 0,
                      Darwin.unlink(marker.path) == 0 else {
                    throw ReleaseQualificationContractError.invalid(
                        field: "cleanup",
                        reason: "owned artifact cleanup did not complete"
                    )
                }
            }
            return removable.map(\.relativePath).sorted()
        }
    }

    public static func replayKey(
        claim: ReleaseQualificationClaim,
        environment: ReleaseQualificationDetectedEnvironment,
        commands: [ReleaseQualificationCommandObservation]
    ) throws -> ReleaseQualificationSHA256 {
        struct ReplayInput: Codable {
            let claim: ReleaseQualificationClaim
            let environment: ReleaseQualificationDetectedEnvironment
            let commands: [ReleaseQualificationCommandObservation]
        }
        return ReleaseQualificationHash.sha256(
            data: try ReleaseQualificationJSON.encode(
                ReplayInput(
                    claim: claim,
                    environment: environment,
                    commands: commands
                )
            )
        )
    }

    private func ensureOwner() throws {
        let ownerURL = root.appendingPathComponent("ledger-owner.json")
        if try ReleaseQualificationFile.isRegularNonSymlink(ownerURL) {
            let owner = try ReleaseQualificationJSON.decode(LedgerOwner.self, from: ownerURL)
            guard owner.ledgerID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            return
        }
        let owner = LedgerOwner(
            ledgerID: String(UUID().uuidString.filter { $0 != "-" }.prefix(32)).lowercased(),
            createdAt: ReleaseQualificationTimestamp()
        )
        try ReleaseQualificationJSON.writeCanonical(owner, to: ownerURL)
    }

    private func readJournals() throws -> [ReleaseQualificationJournal] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: journalsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard entries.count <= ReleaseQualificationLimits.maximumMatrixCells else {
            throw ReleaseQualificationContractError.oversizedInput
        }
        return try entries
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".json") }
            .sorted()
            .map { name in
                guard ReleaseQualificationPath.isSafeRelative(name),
                      name.hasSuffix(".json") else {
                    throw ReleaseQualificationContractError.unsafePath
                }
                let url = journalsDirectory.appendingPathComponent(name)
                guard try ReleaseQualificationFile.isRegularNonSymlink(url) else {
                    throw ReleaseQualificationContractError.tamperedEvidence
                }
                return try readEnvelope(at: url).payload
            }
    }

    private func readRequiredJournal(runID: String) throws -> ReleaseQualificationJournal {
        try validateRunID(runID)
        guard let journal = try readJournalIfPresent(at: journalURL(runID: runID)) else {
            throw ReleaseQualificationContractError.invalid(
                field: "runID",
                reason: "run is not present in the private ledger"
            )
        }
        return journal
    }

    private func readJournalIfPresent(at url: URL) throws -> ReleaseQualificationJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard try ReleaseQualificationFile.isRegularNonSymlink(url) else {
            throw ReleaseQualificationContractError.tamperedEvidence
        }
        return try readEnvelope(at: url).payload
    }

    private func readEnvelope(at url: URL) throws -> LedgerEnvelope {
        let envelope = try ReleaseQualificationJSON.decode(LedgerEnvelope.self, from: url)
        try envelope.validate()
        return envelope
    }

    private func writeJournal(
        _ journal: ReleaseQualificationJournal,
        to url: URL
    ) throws {
        try journal.validate()
        let payload = try ReleaseQualificationJSON.encode(journal)
        let envelope = LedgerEnvelope(
            payload: journal,
            payloadSHA256: ReleaseQualificationHash.sha256(data: payload)
        )
        try ReleaseQualificationFile.writeAtomically(
            data: try ReleaseQualificationJSON.encode(envelope),
            to: url,
            mode: 0o600,
            createParent: false,
            replaceExisting: true
        )
    }

    private func journalURL(runID: String) -> URL {
        journalsDirectory.appendingPathComponent("\(runID).json")
    }

    private func validateRunID(_ runID: String) throws {
        guard runID.range(of: "^[a-z0-9][a-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw ReleaseQualificationContractError.invalid(
                field: "runID",
                reason: "run identity is unsafe"
            )
        }
    }

    private func prepareArtifactParent(_ url: URL) throws {
        guard ReleaseQualificationPath.isContained(url, in: artifactsDirectory) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try ReleaseQualificationFile.validatePrivateDirectory(artifactsDirectory)
        guard url.path != artifactsDirectory.path else { return }
        let relative = String(url.path.dropFirst(artifactsDirectory.path.count + 1))
        guard ReleaseQualificationPath.isSafeRelative(relative) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        var current = artifactsDirectory
        for component in relative.split(separator: "/") {
            let next = current.appendingPathComponent(String(component), isDirectory: true)
            if try ReleaseQualificationFile.isDirectory(next) {
                try ReleaseQualificationFile.validatePrivateDirectory(next)
            } else {
                var metadata = stat()
                guard lstat(next.path, &metadata) != 0, errno == ENOENT else {
                    throw ReleaseQualificationContractError.unsafePath
                }
                try FileManager.default.createDirectory(
                    at: next,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                try ReleaseQualificationFile.validatePrivateDirectory(next)
            }
            current = next
        }
    }

    private func validateArtifactParent(_ url: URL) throws {
        guard ReleaseQualificationPath.isContained(url, in: artifactsDirectory) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try ReleaseQualificationFile.validatePrivateDirectory(artifactsDirectory)
        guard url.path != artifactsDirectory.path else { return }
        let relative = String(url.path.dropFirst(artifactsDirectory.path.count + 1))
        guard ReleaseQualificationPath.isSafeRelative(relative) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        var current = artifactsDirectory
        for component in relative.split(separator: "/") {
            let next = current.appendingPathComponent(String(component), isDirectory: true)
            guard try ReleaseQualificationFile.isDirectory(next) else {
                throw ReleaseQualificationContractError.unsafePath
            }
            try ReleaseQualificationFile.validatePrivateDirectory(next)
            current = next
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func checkCancellation(_ cancellation: SecureSubprocessCancellation) throws {
        guard !cancellation.isCancelled else {
            throw ReleaseQualificationContractError.cancelled
        }
    }

    private static func prepareRoot(_ root: URL, createIfMissing: Bool) throws {
        if try ReleaseQualificationFile.isDirectory(root) {
            try ReleaseQualificationFile.validatePrivateDirectory(root)
            return
        }
        guard createIfMissing,
              !FileManager.default.fileExists(atPath: root.path) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        let parent = root.deletingLastPathComponent()
        guard try ReleaseQualificationFile.isDirectory(parent) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try ReleaseQualificationFile.validatePrivateDirectory(root)
    }

    private static func prepareChild(_ child: URL) throws {
        if try ReleaseQualificationFile.isDirectory(child) {
            try ReleaseQualificationFile.validatePrivateDirectory(child)
            return
        }
        guard !FileManager.default.fileExists(atPath: child.path) else {
            throw ReleaseQualificationContractError.unsafePath
        }
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try ReleaseQualificationFile.validatePrivateDirectory(child)
    }

    private struct LedgerOwner: Codable, Equatable, ReleaseQualificationValidating {
        let schemaVersion: Int
        let ledgerID: String
        let createdAt: ReleaseQualificationTimestamp

        init(ledgerID: String, createdAt: ReleaseQualificationTimestamp) {
            schemaVersion = ReleaseQualificationLimits.schemaVersion
            self.ledgerID = ledgerID
            self.createdAt = createdAt
        }

        func validate() throws {
            guard schemaVersion == ReleaseQualificationLimits.schemaVersion,
                  ledgerID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
            try createdAt.validate()
        }
    }

    private struct LedgerEnvelope: Codable, Equatable, ReleaseQualificationValidating {
        let schemaVersion: Int
        let payload: ReleaseQualificationJournal
        let payloadSHA256: ReleaseQualificationSHA256

        init(
            payload: ReleaseQualificationJournal,
            payloadSHA256: ReleaseQualificationSHA256
        ) {
            schemaVersion = ReleaseQualificationLimits.schemaVersion
            self.payload = payload
            self.payloadSHA256 = payloadSHA256
        }

        func validate() throws {
            guard schemaVersion == ReleaseQualificationLimits.schemaVersion else {
                throw ReleaseQualificationContractError.unsupportedSchemaVersion(schemaVersion)
            }
            try payload.validate()
            try payloadSHA256.validate()
            let data = try ReleaseQualificationJSON.encode(payload)
            guard ReleaseQualificationHash.sha256(data: data) == payloadSHA256 else {
                throw ReleaseQualificationContractError.tamperedEvidence
            }
        }
    }
}
