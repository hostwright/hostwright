import Foundation
import HostwrightRuntime
import XCTest
@testable import HostwrightRuntimeConformanceTool

final class RuntimeQualificationRecoveryReportTests: XCTestCase {
    func testPassedReportMatchesStrictRecoveryEnvelope() throws {
        let hash = String(repeating: "a", count: 64)
        let image = RuntimeLocalImageEvidence(
            reference: "example.local/runtime:1",
            descriptorDigest: "sha256:\(hash)",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let evidence = recoveryEvidence(hash: hash, image: image)
        let report = try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: evidence,
                commands: commands(for: evidence),
                cleanupIdentifiers: ["group-id"]
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "schemaVersion", "kind", "status", "scenario", "subjects", "fixtureImage",
            "inventory", "unmanagedInventoryUnchanged", "summary", "commands", "cleanup",
            "details",
        ])
        XCTAssertEqual(object["kind"] as? String, "runtimeProviderRecoveryEvidence")
        XCTAssertEqual(object["scenario"] as? String, "checkpoint-crash")
        XCTAssertEqual((object["summary"] as? [String: Int])?["failed"], 0)
    }

    func testReportRefusesChangedInventoryOrMissingCommands() {
        let hash = String(repeating: "a", count: 64)
        let image = RuntimeLocalImageEvidence(
            reference: "example.local/runtime:1",
            descriptorDigest: "sha256:\(hash)",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
        var evidence = recoveryEvidence(hash: hash, image: image)
        evidence = RuntimeQualificationRecoveryEvidence(
            schemaVersion: evidence.schemaVersion,
            scenario: evidence.scenario,
            providerID: evidence.providerID,
            providerVersion: evidence.providerVersion,
            fixtureImageReference: evidence.fixtureImageReference,
            fixtureImageDescriptorDigest: evidence.fixtureImageDescriptorDigest,
            fixtureImageVariantDigest: evidence.fixtureImageVariantDigest,
            fixtureImageArchitecture: evidence.fixtureImageArchitecture,
            fixtureImageOperatingSystem: evidence.fixtureImageOperatingSystem,
            capabilityBeforeSHA256: evidence.capabilityBeforeSHA256,
            capabilityAfterSHA256: evidence.capabilityAfterSHA256,
            inventoryBeforeSHA256: evidence.inventoryBeforeSHA256,
            inventoryAfterSHA256: String(repeating: "c", count: 64),
            unmanagedInventoryBeforeSHA256: evidence.unmanagedInventoryBeforeSHA256,
            unmanagedInventoryAfterSHA256: evidence.unmanagedInventoryAfterSHA256,
            unmanagedInventoryUnchanged: evidence.unmanagedInventoryUnchanged,
            recoveryDisposition: evidence.recoveryDisposition,
            recoveryChangeKinds: evidence.recoveryChangeKinds,
            recoveryFindingReasons: evidence.recoveryFindingReasons,
            capabilitySnapshotInvalidated: evidence.capabilitySnapshotInvalidated,
            providerGeneration: evidence.providerGeneration,
            providerMetadataRevisionBefore: evidence.providerMetadataRevisionBefore,
            providerMetadataRevisionAfter: evidence.providerMetadataRevisionAfter,
            contractInput: evidence.contractInput,
            durableCheckpointBefore: evidence.durableCheckpointBefore,
            durableCheckpointAfter: evidence.durableCheckpointAfter,
            terminatedExecutable: evidence.terminatedExecutable,
            processTreeTerminated: evidence.processTreeTerminated,
            stateSchemaVersion: evidence.stateSchemaVersion,
            passedAssertions: evidence.passedAssertions,
            failedAssertions: evidence.failedAssertions,
            cleanupComplete: evidence.cleanupComplete,
            cleanupIdentifiers: evidence.cleanupIdentifiers
        )
        XCTAssertThrowsError(try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: evidence,
                commands: [],
                cleanupIdentifiers: []
            )
        ))
    }

    func testReportAcceptsEveryLockedRecoveryScenarioShape() throws {
        let hash = String(repeating: "a", count: 64)
        let image = RuntimeLocalImageEvidence(
            reference: "example.local/runtime:1",
            descriptorDigest: "sha256:\(hash)",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )

        for scenario in RuntimeQualificationRecoveryScenario.allCases {
            let providerID: RuntimeProviderID = switch scenario {
            case .helperRestart, .staleHelper: .appleContainerization
            default: .appleContainerCLI
            }
            let evidence = recoveryEvidence(
                hash: hash,
                image: image,
                scenario: scenario,
                providerID: providerID
            )
            XCTAssertNoThrow(
                try RuntimeQualificationRecoveryReport.passed(execution:
                    RuntimeQualificationRecoveryExecution(
                        fixtureImage: image,
                        evidence: evidence,
                        commands: commands(for: evidence),
                        cleanupIdentifiers: evidence.cleanupIdentifiers
                    )
                ),
                scenario.rawValue
            )
        }
    }

    func testReportRefusesCleanupDriftAndScenarioSpecificFalsePositive() throws {
        let hash = String(repeating: "a", count: 64)
        let image = RuntimeLocalImageEvidence(
            reference: "example.local/runtime:1",
            descriptorDigest: "sha256:\(hash)",
            variantDigest: "sha256:\(String(repeating: "b", count: 64))",
            architecture: "arm64",
            operatingSystem: "linux"
        )
        let evidence = recoveryEvidence(hash: hash, image: image)
        XCTAssertThrowsError(try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: evidence,
                commands: commands(for: evidence),
                cleanupIdentifiers: ["different-group"]
            )
        ))

        XCTAssertThrowsError(try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: evidence,
                commands: [command(for: evidence)],
                cleanupIdentifiers: evidence.cleanupIdentifiers
            )
        ))

        let data = try JSONEncoder().encode(evidence)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["processTreeTerminated"] = false
        let invalidEvidence = try JSONDecoder().decode(
            RuntimeQualificationRecoveryEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: invalidEvidence,
                commands: commands(for: invalidEvidence),
                cleanupIdentifiers: invalidEvidence.cleanupIdentifiers
            )
        ))

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["providerMetadataRevisionAfter"] =
            RuntimeProviderMetadataEvidence.legacyRevision
        let revisionDrift = try JSONDecoder().decode(
            RuntimeQualificationRecoveryEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try RuntimeQualificationRecoveryReport.passed(execution:
            RuntimeQualificationRecoveryExecution(
                fixtureImage: image,
                evidence: revisionDrift,
                commands: commands(for: revisionDrift),
                cleanupIdentifiers: revisionDrift.cleanupIdentifiers
            )
        ))
    }

    private func recoveryEvidence(
        hash: String,
        image: RuntimeLocalImageEvidence,
        scenario: RuntimeQualificationRecoveryScenario = .checkpointCrash,
        providerID: RuntimeProviderID = .appleContainerCLI
    ) -> RuntimeQualificationRecoveryEvidence {
        let drifted = [
            RuntimeQualificationRecoveryScenario.mixedComponentVersions,
            .staleHelper,
            .futureProtocolRefusal,
        ].contains(scenario)
        let disposition: RuntimeProviderRecoveryDisposition = switch scenario {
        case .mixedComponentVersions, .futureProtocolRefusal, .downgradeRefusal:
            .refuseAndPreserveCheckpoint
        case .staleHelper:
            .reobserveThenResumeFromCheckpoint
        default:
            .resumeFromCheckpoint
        }
        let reasons: [String] = switch scenario {
        case .mixedComponentVersions:
            [RuntimeProviderRecoveryFindingReason.mixedComponents.rawValue]
        case .futureProtocolRefusal:
            [RuntimeProviderRecoveryFindingReason.unsupportedFutureProtocol.rawValue]
        case .downgradeRefusal:
            [RuntimeProviderRecoveryFindingReason.metadataRevisionTooNew.rawValue]
        default:
            []
        }
        let contractInput: String = switch scenario {
        case .mixedComponentVersions:
            "mixed-component-contract-injection-from-live-snapshot"
        case .staleHelper:
            "stale-helper-contract-injection-from-live-snapshot"
        case .futureProtocolRefusal:
            "future-protocol-contract-injection-from-live-snapshot"
        case .downgradeRefusal:
            "future-metadata-revision-against-live-snapshot"
        default:
            "live-provider-snapshot"
        }
        let processCycle = scenario == .hostwrightTermination || scenario == .checkpointCrash
        let checkpointBefore: String? = switch scenario {
        case .hostwrightTermination: "prepared"
        case .checkpointCrash: "runtime-effect-recorded"
        default: nil
        }
        let checkpointAfter: String? = switch scenario {
        case .hostwrightTermination: "recovered-after-hostwright-termination"
        case .checkpointCrash: "recovered-after-checkpoint-crash"
        default: nil
        }
        let metadataRevision = scenario == .downgradeRefusal
            ? RuntimeProviderMetadataEvidence.currentRevision + 1
            : RuntimeProviderMetadataEvidence.currentRevision
        return RuntimeQualificationRecoveryEvidence(
            schemaVersion: 1,
            scenario: scenario.rawValue,
            providerID: providerID.rawValue,
            providerVersion: providerID == .appleContainerCLI ? "1.1.0" : "0.35.0",
            fixtureImageReference: image.reference,
            fixtureImageDescriptorDigest: image.descriptorDigest,
            fixtureImageVariantDigest: image.variantDigest,
            fixtureImageArchitecture: image.architecture,
            fixtureImageOperatingSystem: image.operatingSystem,
            capabilityBeforeSHA256: hash,
            capabilityAfterSHA256: drifted ? String(repeating: "c", count: 64) : hash,
            inventoryBeforeSHA256: hash,
            inventoryAfterSHA256: hash,
            unmanagedInventoryBeforeSHA256: String(repeating: "d", count: 64),
            unmanagedInventoryAfterSHA256: String(repeating: "d", count: 64),
            unmanagedInventoryUnchanged: true,
            recoveryDisposition: disposition.rawValue,
            recoveryChangeKinds: drifted
                ? [RuntimeProviderRecoveryChangeKind.capabilityDigest.rawValue] : [],
            recoveryFindingReasons: reasons,
            capabilitySnapshotInvalidated: drifted,
            providerGeneration: 1,
            providerMetadataRevisionBefore: metadataRevision,
            providerMetadataRevisionAfter: metadataRevision,
            contractInput: contractInput,
            durableCheckpointBefore: checkpointBefore,
            durableCheckpointAfter: checkpointAfter,
            terminatedExecutable: processCycle ? "hostwright-runtime-conformance" : nil,
            processTreeTerminated: processCycle,
            stateSchemaVersion: processCycle ? 7 : nil,
            passedAssertions: 8,
            failedAssertions: 0,
            cleanupComplete: true,
            cleanupIdentifiers: processCycle ? ["group-id"] : []
        )
    }

    private func command(
        for evidence: RuntimeQualificationRecoveryEvidence
    ) -> RuntimeQualificationCommandEvidence {
        RuntimeQualificationCommandEvidence(
            arguments: [
                "hostwright-runtime-conformance", "recovery",
                evidence.providerID, evidence.scenario,
            ],
            exitStatus: 0
        )
    }

    private func commands(
        for evidence: RuntimeQualificationRecoveryEvidence
    ) -> [RuntimeQualificationCommandEvidence] {
        var result: [RuntimeQualificationCommandEvidence] = []
        if evidence.scenario == RuntimeQualificationRecoveryScenario.hostwrightTermination.rawValue ||
            evidence.scenario == RuntimeQualificationRecoveryScenario.checkpointCrash.rawValue {
            result.append(RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance", "recovery-worker-write"],
                exitStatus: -1
            ))
            result.append(RuntimeQualificationCommandEvidence(
                arguments: ["hostwright-runtime-conformance", "recovery-worker-resume"],
                exitStatus: 0
            ))
        }
        result.append(command(for: evidence))
        return result
    }
}
