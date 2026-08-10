import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry
import HostwrightState
import XCTest
@testable import HostwrightCLI

final class RegistrySBOMExecutionTests: XCTestCase {
    func testExportFailureAfterFileEffectIsResumable() {
        XCTAssertEqual(
            RegistrySBOMCommandRunner.exportFailureStatus(
                outputApplied: false
            ),
            .failed
        )
        XCTAssertEqual(
            RegistrySBOMCommandRunner.exportFailureStatus(
                outputApplied: true
            ),
            .interrupted
        )
    }

    func testIngestQueryAndExportUseExactVerifiedGraph() throws {
        let directory = try secureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let manifestPath = directory
            .appendingPathComponent("hostwright.yml").path
        let exportPath = directory
            .appendingPathComponent("image.spdx.json").path
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "a", count: 64)
        )
        try manifest(subject: subject).write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestPath
        )
        let payload = try spdx(subject: subject)
        let artifact = try ImageSBOMArtifact.make(
            documentPayload: payload,
            expectedFormat: .spdxJSON,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: subject,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/image")
        )
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let discovery = try store.ociReferrers.saveGraph(
            artifact.graph,
            observedAt: "2026-07-24T20:00:00Z"
        )

        let ingest = try RegistrySBOMCommandRunner(
            action: .ingest(
                discoveryID: discovery.id,
                manifestPath: manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()
        XCTAssertTrue(
            ingest.standardOutput.contains(#""status":"verified""#)
        )
        XCTAssertTrue(
            ingest.standardOutput.contains(
                artifact.document.documentDigest.canonicalValue
            )
        )

        let query = try RegistrySBOMCommandRunner(
            action: .query(
                manifestPath: manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()
        XCTAssertTrue(
            query.standardOutput.contains(#""status":"satisfied""#)
        )

        let exported = try RegistrySBOMCommandRunner(
            action: .export(
                manifestPath: manifestPath,
                serviceName: "api",
                format: "spdx-json",
                outputPath: exportPath
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()
        XCTAssertTrue(
            exported.standardOutput.contains(#""status":"verified""#)
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: exportPath)),
            payload
        )
        XCTAssertThrowsError(
            try RegistrySBOMCommandRunner(
                action: .export(
                    manifestPath: manifestPath,
                    serviceName: "api",
                    format: "spdx-json",
                    outputPath: exportPath
                ),
                stateDatabasePath: statePath,
                output: .json,
                environment: .live
            ).run()
        )

        let resumedExportPath = directory
            .appendingPathComponent("resumed.spdx.json").path
        try payload.write(
            to: URL(fileURLWithPath: resumedExportPath),
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: resumedExportPath
        )
        let policy = try ImageSBOMPolicyMapping.map(
            ManifestParser.parse(manifest(subject: subject))
        )
        let intent: [String: Any] = [
            "apiVersion": "hostwright.dev/image-sbom/v1",
            "operation": "export",
            "projectID": "project-demo",
            "serviceName": "api",
            "descriptorDigest": subject.canonicalValue,
            "policySHA256": policy.policySHA256,
            "manifestPath": manifestPath,
            "requestedServiceName": "api",
            "format": "spdx-json",
            "documentDigest":
                artifact.document.documentDigest.canonicalValue,
            "outputPath": resumedExportPath,
            "outputPathSHA256":
                sha256(Data(resumedExportPath.utf8))
        ]
        let intentData = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let plan = sha256(intentData)
        let groupID = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: groupID,
            operationID: groupID,
            groupKind: "image-sbom",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "export",
            status: .active,
            groupIdempotencyKey: plan,
            planHash: plan,
            checkpoint: "intent-persisted",
            lockOwner: "test-owner",
            lockExpiresAt: "2026-07-24T00:01:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "resume",
            createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z",
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted:
                String(decoding: intentData, as: UTF8.self),
            compensationJSONRedacted:
                #"[{"deleteOnlyExactNewOutput":true}]"#,
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                group,
                currentTimestamp: "2026-07-24T00:00:00Z"
            ).acquired
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "interrupted-after-export",
            manualRecoveryHintRedacted: "resume exact export",
            updatedAt: "2026-07-24T00:02:00Z",
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
        let resumed = try RegistrySBOMCommandRunner(
            action: .resume(
                operationGroupID: group.id,
                confirmationPlanSHA256: plan
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()
        XCTAssertTrue(
            resumed.standardOutput.contains(#""status":"verified""#)
        )
        XCTAssertEqual(
            try store.operationGroups.load(id: group.id)?.status,
            .succeeded
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(
                    fileURLWithPath: resumedExportPath
                )
            ),
            payload
        )

        let mismatchedPath = directory
            .appendingPathComponent("mismatched.spdx.json").path
        let mismatchedPayload = Data("not-the-sbom".utf8)
        try mismatchedPayload.write(
            to: URL(fileURLWithPath: mismatchedPath),
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: mismatchedPath
        )
        var mismatchedIntent = intent
        mismatchedIntent["outputPath"] = mismatchedPath
        mismatchedIntent["outputPathSHA256"] =
            sha256(Data(mismatchedPath.utf8))
        let mismatchedIntentData = try JSONSerialization.data(
            withJSONObject: mismatchedIntent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let mismatchedPlan = sha256(mismatchedIntentData)
        let mismatchedGroupID = UUID().uuidString.lowercased()
        let mismatchedGroup = OperationGroupRecord(
            id: mismatchedGroupID,
            operationID: mismatchedGroupID,
            groupKind: "image-sbom",
            projectID: "project-demo",
            serviceName: "api",
            plannedActionType: "export",
            status: .active,
            groupIdempotencyKey: mismatchedPlan,
            planHash: mismatchedPlan,
            checkpoint: "intent-persisted",
            lockOwner: "test-owner",
            lockExpiresAt: "2026-07-24T00:01:00Z",
            rollbackAvailable: true,
            manualRecoveryHintRedacted: "resume",
            createdAt: "2026-07-24T00:00:00Z",
            updatedAt: "2026-07-24T00:00:00Z",
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted:
                String(
                    decoding: mismatchedIntentData,
                    as: UTF8.self
                ),
            compensationJSONRedacted:
                #"[{"deleteOnlyExactNewOutput":true}]"#,
            verificationJSONRedacted: "{}"
        )
        XCTAssertNotNil(
            try store.operationGroups.acquire(
                mismatchedGroup,
                currentTimestamp: "2026-07-24T00:00:00Z"
            ).acquired
        )
        try store.operationGroups.finish(
            groupID: mismatchedGroup.id,
            status: .interrupted,
            checkpoint: "interrupted-after-export",
            manualRecoveryHintRedacted: "resume exact export",
            updatedAt: "2026-07-24T00:02:00Z",
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
        XCTAssertThrowsError(
            try RegistrySBOMCommandRunner(
                action: .resume(
                    operationGroupID: mismatchedGroup.id,
                    confirmationPlanSHA256: mismatchedPlan
                ),
                stateDatabasePath: statePath,
                output: .json,
                environment: .live
            ).run()
        )
        XCTAssertEqual(
            try store.operationGroups.load(id: mismatchedGroup.id)?
                .status,
            .failed
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(fileURLWithPath: mismatchedPath)
            ),
            mismatchedPayload
        )
    }

    func testPostWriteFinalizationFailurePersistsExactResumableExport()
        throws
    {
        let directory = try secureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let manifestPath = directory
            .appendingPathComponent("hostwright.yml").path
        let exportPath = directory
            .appendingPathComponent("recoverable.spdx.json").path
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "e", count: 64)
        )
        try manifest(subject: subject).write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestPath
        )
        let payload = try spdx(subject: subject)
        let artifact = try ImageSBOMArtifact.make(
            documentPayload: payload,
            expectedFormat: .spdxJSON,
            subjectDescriptor: try OCIContentDescriptor(
                mediaType:
                    OCIReferrerDescriptor.manifestMediaType,
                digest: subject,
                size: 512
            ),
            endpoint: try RegistryEndpoint(
                "https://registry.example.test"
            ),
            repository: try OCIRepositoryName("team/image")
        )
        let store = SQLiteStateStore(path: statePath)
        try store.migrate()
        let discovery = try store.ociReferrers.saveGraph(
            artifact.graph,
            observedAt: "2026-07-24T20:00:00Z"
        )
        _ = try RegistrySBOMCommandRunner(
            action: .ingest(
                discoveryID: discovery.id,
                manifestPath: manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()

        try runSQLite(
            databasePath: statePath,
            statement:
                """
                CREATE TRIGGER fail_export_checkpoint
                BEFORE UPDATE OF checkpoint ON operation_groups
                WHEN NEW.checkpoint = 'export-observed'
                BEGIN
                  SELECT RAISE(FAIL, 'injected export checkpoint failure');
                END;
                """
        )
        XCTAssertThrowsError(
            try RegistrySBOMCommandRunner(
                action: .export(
                    manifestPath: manifestPath,
                    serviceName: "api",
                    format: "spdx-json",
                    outputPath: exportPath
                ),
                stateDatabasePath: statePath,
                output: .json,
                environment: .live
            ).run()
        )
        let interrupted = try XCTUnwrap(
            store.operationGroups.loadAll().last(where: {
                $0.groupKind == "image-sbom" &&
                    $0.plannedActionType == "export"
            })
        )
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(
            interrupted.checkpoint,
            "export-written-finalization-interrupted"
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(fileURLWithPath: exportPath)
            ),
            payload
        )

        try runSQLite(
            databasePath: statePath,
            statement:
                "DROP TRIGGER fail_export_checkpoint;"
        )
        let resumed = try RegistrySBOMCommandRunner(
            action: .resume(
                operationGroupID: interrupted.id,
                confirmationPlanSHA256: interrupted.planHash
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()
        XCTAssertTrue(
            resumed.standardOutput.contains(#""status":"verified""#)
        )
        XCTAssertEqual(
            try store.operationGroups.load(id: interrupted.id)?
                .status,
            .succeeded
        )
        XCTAssertEqual(
            try Data(
                contentsOf: URL(fileURLWithPath: exportPath)
            ),
            payload
        )
    }

    func testRequiredQueryReportsMissingWithoutEffects() throws {
        let directory = try secureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let manifestPath = directory
            .appendingPathComponent("hostwright.yml").path
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "b", count: 64)
        )
        try manifest(subject: subject).write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )

        let query = try RegistrySBOMCommandRunner(
            action: .query(
                manifestPath: manifestPath,
                serviceName: "api"
            ),
            stateDatabasePath: statePath,
            output: .json,
            environment: .live
        ).run()

        XCTAssertTrue(
            query.standardOutput.contains(
                #""status":"required-missing""#
            )
        )
        XCTAssertEqual(
            try SQLiteStateStore(path: statePath)
                .operationGroups.loadAll(),
            []
        )
    }

    func testCancelledGenerationPersistsResumableIntentWithoutGraph()
        throws
    {
        let directory = try secureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let statePath = directory
            .appendingPathComponent("state.sqlite").path
        let manifestPath = directory
            .appendingPathComponent("hostwright.yml").path
        let archivePath = directory
            .appendingPathComponent("image.oci.tar").path
        let subject = try OCIContentDigest(
            "sha256:" + String(repeating: "c", count: 64)
        )
        try manifest(subject: subject).write(
            toFile: manifestPath,
            atomically: false,
            encoding: .utf8
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: archivePath,
                contents: Data([0]),
                attributes: [.posixPermissions: 0o600]
            )
        )
        let cancellation = SecureSubprocessCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try RegistrySBOMCommandRunner(
                action: .generate(
                    archivePath: archivePath,
                    manifestPath: manifestPath,
                    serviceName: "api",
                    server: "registry.example.test",
                    repository: "team/image",
                    format: "spdx-json",
                    provenanceDescriptorDigest: nil,
                    provenanceReferrerDigest: nil
                ),
                stateDatabasePath: statePath,
                output: .json,
                environment: .live,
                cancellation: cancellation
            ).run()
        ) {
            XCTAssertEqual(
                ($0 as? HostwrightDiagnostic)?.code,
                .partialFailure
            )
        }
        let store = SQLiteStateStore(path: statePath)
        let groups = try store.operationGroups.loadAll()
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].status, .interrupted)
        XCTAssertEqual(groups[0].groupKind, "image-sbom")
        XCTAssertEqual(
            try store.ociReferrers.latestDiscovery(
                endpoint: "https://registry.example.test",
                repository: "team/image",
                subjectDigest: subject.canonicalValue,
                artifactType: nil
            ),
            nil
        )
    }

    private func secureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "hostwright-sbom-cli-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func runSQLite(
        databasePath: String,
        statement: String
    ) throws {
        let executable = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(
            atPath: executable
        ) else {
            throw XCTSkip("The required macOS sqlite3 tool is unavailable.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [databasePath, statement]
        let errorOutput = Pipe()
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()
        let errorData =
            errorOutput.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: errorData, as: UTF8.self)
        )
    }

    private func manifest(
        subject: OCIContentDigest
    ) -> String {
        """
        version: 3
        project: demo
        imagePolicy: require-digest
        imageSBOM:
          version: 1
          requirement: required
          formats:
            - spdx-json
        services:
          api:
            image: registry.example.test/team/image@\(subject.canonicalValue)
        """
    }

    private func spdx(subject: OCIContentDigest) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "spdxVersion": "SPDX-2.3",
                "dataLicense": "CC0-1.0",
                "SPDXID": "SPDXRef-DOCUMENT",
                "name": "image sbom",
                "documentNamespace": "urn:hostwright:test",
                "creationInfo": [
                    "created": "2026-07-24T20:00:00Z",
                    "creators": ["Tool: tests"]
                ],
                "packages": [[
                    "name": "image",
                    "SPDXID": "SPDXRef-image",
                    "checksums": [[
                        "algorithm": "SHA256",
                        "checksumValue": subject.encoded
                    ]]
                ]]
            ],
            options: [.sortedKeys]
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
