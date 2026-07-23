import CryptoKit
import Foundation
import HostwrightRuntime

enum RuntimeQualificationMigrationReportError: Error, Equatable {
    case invalidDriverEvidence
    case invalidCommandEvidence
}

enum RuntimeQualificationMigrationReportComposer {
    static func compose(
        specification: RuntimeQualificationMigrationSpecification,
        evidence: RuntimeQualificationMigrationEvidence,
        commands: [RuntimeQualificationCommandEvidence]
    ) throws -> RuntimeQualificationMigrationReport {
        let specification = try specification.validated()
        guard valid(evidence, for: specification) else {
            throw RuntimeQualificationMigrationReportError.invalidDriverEvidence
        }
        guard valid(commands) else {
            throw RuntimeQualificationMigrationReportError.invalidCommandEvidence
        }

        let beforeSHA256 = combinedInventorySHA256(
            sourceProviderID: evidence.sourceProviderID,
            sourceSHA256: evidence.sourceInventoryBeforeSHA256,
            targetProviderID: evidence.targetProviderID,
            targetSHA256: evidence.targetInventoryBeforeSHA256
        )
        let afterSHA256 = combinedInventorySHA256(
            sourceProviderID: evidence.sourceProviderID,
            sourceSHA256: evidence.sourceInventoryAfterSHA256,
            targetProviderID: evidence.targetProviderID,
            targetSHA256: evidence.targetInventoryAfterSHA256
        )
        guard beforeSHA256 == afterSHA256 else {
            throw RuntimeQualificationMigrationReportError.invalidDriverEvidence
        }

        let passedChecks = [
            evidence.staleConfirmationRefused,
            evidence.targetCollisionRefused,
            evidence.unavailableImageRefused,
            evidence.rollbackVerified,
            evidence.checkpointRecovered,
            evidence.forwardCheckpoint == "sourceRetired",
            evidence.reverseCheckpoint == "sourceRetired",
            evidence.stateSchemaVersion == 7,
            evidence.sourceInventoryBeforeSHA256 == evidence.sourceInventoryAfterSHA256,
            evidence.targetInventoryBeforeSHA256 == evidence.targetInventoryAfterSHA256,
            evidence.cleanupComplete,
        ]

        return RuntimeQualificationMigrationReport(
            schemaVersion: 1,
            kind: "runtimeProviderMigrationEvidence",
            status: "passed",
            subjects: [
                RuntimeQualificationSubject(
                    providerID: specification.sourceProviderID.rawValue,
                    providerVersion: specification.expectedSourceVersion
                ),
                RuntimeQualificationSubject(
                    providerID: specification.targetProviderID.rawValue,
                    providerVersion: specification.expectedTargetVersion
                ),
            ],
            fixtureImage: RuntimeQualificationFixtureImage(
                reference: evidence.fixtureImageReference,
                digest: evidence.fixtureImageDescriptorDigest
            ),
            inventory: RuntimeQualificationInventoryEvidence(
                beforeSHA256: beforeSHA256,
                afterSHA256: afterSHA256,
                unmanagedBeforeSHA256: beforeSHA256,
                unmanagedAfterSHA256: afterSHA256
            ),
            unmanagedInventoryUnchanged: true,
            summary: RuntimeQualificationSummary(
                passed: passedChecks.filter { $0 }.count,
                failed: 0
            ),
            commands: commands,
            cleanup: RuntimeQualificationCleanupEvidence(
                complete: true,
                identifiers: [evidence.projectUUID, evidence.resourceUUID].sorted()
            ),
            details: RuntimeQualificationMigrationDetails(migration: evidence)
        )
    }

    private static func valid(
        _ evidence: RuntimeQualificationMigrationEvidence,
        for specification: RuntimeQualificationMigrationSpecification
    ) -> Bool {
        evidence.schemaVersion == 1 &&
            evidence.sourceProviderID == specification.sourceProviderID.rawValue &&
            evidence.targetProviderID == specification.targetProviderID.rawValue &&
            canonicalUUID(evidence.projectUUID) &&
            canonicalUUID(evidence.resourceUUID) &&
            evidence.projectUUID != evidence.resourceUUID &&
            evidence.fixtureImageReference == specification.localImage &&
            ociDigest(evidence.fixtureImageDescriptorDigest) &&
            ociDigest(evidence.fixtureImageVariantDigest) &&
            sha256(evidence.sourceCapabilitySHA256) &&
            sha256(evidence.targetCapabilitySHA256) &&
            evidence.staleConfirmationRefused &&
            evidence.targetCollisionRefused &&
            evidence.unavailableImageRefused &&
            evidence.rollbackVerified &&
            evidence.checkpointRecovered &&
            evidence.forwardCheckpoint == "sourceRetired" &&
            evidence.reverseCheckpoint == "sourceRetired" &&
            evidence.stateSchemaVersion == 7 &&
            sha256(evidence.sourceInventoryBeforeSHA256) &&
            sha256(evidence.sourceInventoryAfterSHA256) &&
            sha256(evidence.targetInventoryBeforeSHA256) &&
            sha256(evidence.targetInventoryAfterSHA256) &&
            evidence.sourceInventoryBeforeSHA256 == evidence.sourceInventoryAfterSHA256 &&
            evidence.targetInventoryBeforeSHA256 == evidence.targetInventoryAfterSHA256 &&
            evidence.cleanupComplete
    }

    private static func valid(_ commands: [RuntimeQualificationCommandEvidence]) -> Bool {
        guard !commands.isEmpty, commands.count <= 256 else { return false }
        return commands.allSatisfy { command in
            !command.arguments.isEmpty &&
                command.arguments.count <= 128 &&
                (-1...255).contains(command.exitStatus) &&
                command.arguments.enumerated().allSatisfy { index, argument in
                    safeArgument(argument) &&
                        (index != 0 || URL(fileURLWithPath: argument).lastPathComponent == argument)
                }
        }
    }

    private static func safeArgument(_ value: String) -> Bool {
        !value.isEmpty &&
            value.utf8.count <= 4_096 &&
            value.rangeOfCharacter(from: .controlCharacters) == nil &&
            value.range(
                of: #"(?i)(password|secret|credential|authorization|cookie|private.?key|api.?key|bearer|access.?token|refresh.?token|session.?token|confirmation.?token)"#,
                options: .regularExpression
            ) == nil
    }

    private static func combinedInventorySHA256(
        sourceProviderID: String,
        sourceSHA256: String,
        targetProviderID: String,
        targetSHA256: String
    ) -> String {
        let canonical = [
            "schemaVersion=1",
            "sourceProviderID=\(sourceProviderID)",
            "sourceInventorySHA256=\(sourceSHA256)",
            "targetProviderID=\(targetProviderID)",
            "targetInventorySHA256=\(targetSHA256)",
        ].joined(separator: "\n") + "\n"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func sha256(_ value: String) -> Bool {
        value.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }

    private static func ociDigest(_ value: String) -> Bool {
        value.range(of: #"\Asha256:[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }
}
