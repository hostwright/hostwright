import Foundation
import HostwrightCore
@testable import HostwrightReleaseQualification

enum ReleaseQualificationTestSupport {
    static let commit = try! ReleaseQualificationCommit(
        "1111111111111111111111111111111111111111"
    )
    static let timestamp = try! ReleaseQualificationTimestamp(
        "2026-08-12T12:00:00.000Z"
    )

    static func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 {
            url.deleteLastPathComponent()
        }
        return url
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hostwright-release-qualification-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    static func source(dirty: Bool = false) -> ReleaseQualificationSourceFacts {
        ReleaseQualificationSourceFacts(
            availability: .init(status: .available),
            commit: commit,
            dirty: dirty,
            dirtyStateSHA256: ReleaseQualificationHash.sha256(
                data: Data((dirty ? "dirty" : "clean").utf8)
            )
        )
    }

    static func host(
        macOSMajor: Int = 26,
        architecture: ReleaseQualificationArchitecture = .arm64,
        model: String = "MacBookPro18,1",
        arm64Capability: Bool = true
    ) -> ReleaseQualificationHostFacts {
        ReleaseQualificationHostFacts(
            availability: .init(status: .available),
            macOSVersion: ReleaseQualificationSemanticVersion(
                major: macOSMajor,
                minor: 0,
                patch: 0
            ),
            build: "26A1",
            architecture: architecture,
            hardwareModel: model,
            memoryBytes: 16 * 1_024 * 1_024 * 1_024,
            arm64Capability: arm64Capability
        )
    }

    static func commandObservation(
        workingDirectory: String = "/"
    ) -> ReleaseQualificationCommandObservation {
        let identity = try! ReleaseQualificationCommandIdentity(
            executablePath: "/usr/bin/true",
            arguments: ["--version"],
            workingDirectory: workingDirectory,
            purpose: "fixture command"
        )
        return ReleaseQualificationCommandObservation(
            identity: identity,
            startedAt: timestamp,
            endedAt: timestamp,
            durationMilliseconds: 1,
            exitStatus: 0,
            standardOutputSHA256: ReleaseQualificationHash.sha256(data: Data("out".utf8)),
            standardErrorSHA256: ReleaseQualificationHash.sha256(data: Data("err".utf8)),
            standardOutputBytes: 3,
            standardErrorBytes: 3
        )
    }

    static func environment(
        source: ReleaseQualificationSourceFacts? = nil,
        host: ReleaseQualificationHostFacts? = nil,
        workingDirectory: String = "/"
    ) -> ReleaseQualificationDetectedEnvironment {
        let command = commandObservation(workingDirectory: workingDirectory)
        let appleContainer = ReleaseQualificationToolFact(
            tool: .appleContainer,
            origin: .process,
            availability: .init(status: .available),
            executablePath: "/usr/bin/container",
            version: ReleaseQualificationSemanticVersion(major: 1, minor: 0, patch: 0),
            rawOutputSHA256: ReleaseQualificationHash.sha256(data: Data("1.0.0".utf8)),
            command: command.identity
        )
        let containerization = ReleaseQualificationToolFact(
            tool: .containerizationFramework,
            origin: .packageResolved,
            availability: .init(status: .available),
            executablePath: nil,
            version: ReleaseQualificationSemanticVersion(major: 0, minor: 35, patch: 0),
            rawOutputSHA256: ReleaseQualificationHash.sha256(data: Data("0.35.0".utf8)),
            command: nil
        )
        return ReleaseQualificationDetectedEnvironment(
            source: source ?? self.source(),
            host: host ?? self.host(),
            tools: [containerization, appleContainer],
            commands: [command]
        )
    }

    static func claim(
        cell: ReleaseQualificationMatrixCell? = nil
    ) -> ReleaseQualificationClaim {
        let selected = cell ?? ReleaseQualificationSupportedMatrix.committed.cells[0]
        return ReleaseQualificationClaim(
            id: "test.\(selected.id)",
            title: selected.claim,
            matrixCellID: selected.id,
            executionMode: selected.executionMode,
            authority: selected.authority,
            requiredEvidenceClasses: selected.requiredEvidenceClasses
        )
    }

    static func evidence(
        environment: ReleaseQualificationDetectedEnvironment? = nil,
        status: ReleaseQualificationOutcomeStatus = .passed,
        blockers: [ReleaseQualificationBlocker] = [],
        failures: [String] = [],
        artifacts: [ReleaseQualificationOwnedArtifact] = [],
        runID: String = "test-run"
    ) throws -> ReleaseQualificationEvidence {
        let selectedEnvironment = environment ?? self.environment()
        let claim = self.claim()
        let commands = selectedEnvironment.commands
        let hashes = commands.flatMap {
            [$0.standardOutputSHA256, $0.standardErrorSHA256]
        }
        let replayKey = try ReleaseQualificationLedgerStore.replayKey(
            claim: claim,
            environment: selectedEnvironment,
            commands: commands
        )
        return ReleaseQualificationEvidence(
            runID: runID,
            claim: claim,
            status: status,
            simulation: .real,
            source: selectedEnvironment.source,
            environment: selectedEnvironment,
            startedAt: timestamp,
            endedAt: timestamp,
            durationMilliseconds: 1,
            commands: commands,
            rawOutputSHA256: hashes,
            artifacts: artifacts,
            blockers: blockers,
            failures: failures,
            replayKey: replayKey
        )
    }

    static func blocker(
        _ reason: ReleaseQualificationUnsupportedReason = .missingExplicitAuthority
    ) -> ReleaseQualificationBlocker {
        ReleaseQualificationBlocker(
            reason: reason,
            field: "test",
            detail: "explicit test blocker"
        )
    }
}
