import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState

struct RegistryTrustCommandRunner {
    let action: RegistryTrustCLIAction
    let stateDatabasePath: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        do {
            switch action {
            case .verify(
                let discoveryID,
                let manifestPath,
                let subjectManifestPath,
                let cosignPath,
                let serviceName
            ):
                return try verify(
                    discoveryID: discoveryID,
                    manifestPath: manifestPath,
                    subjectManifestPath: subjectManifestPath,
                    cosignPath: cosignPath,
                    requestedServiceName: serviceName
                )
            case .status(let manifestPath, let serviceName):
                return try status(
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName
                )
            case .grantException(
                let approvalRecordPath,
                let manifestPath
            ):
                return try grantException(
                    approvalRecordPath: approvalRecordPath,
                    manifestPath: manifestPath
                )
            case .revokeException(let exceptionID):
                return try revokeException(exceptionID: exceptionID)
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch let error as StateStoreError {
            throw HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        } catch let error as ImageTrustVerifierError {
            throw trustDiagnostic(error)
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image trust operation failed before changing runtime state."
            )
        }
    }

    private func verify(
        discoveryID: String,
        manifestPath: String,
        subjectManifestPath: String,
        cosignPath: String,
        requestedServiceName: String?
    ) throws -> CLIRunResult {
        let manifest = try validatedManifest(at: manifestPath)
        let mapping = try ImageTrustPolicyMapping.map(manifest)
        let serviceName = try ImageTrustPolicyMapping.selectService(
            requestedServiceName,
            manifest: manifest
        )
        let binding = try serviceBinding(
            named: serviceName,
            manifest: manifest
        )
        let store = try migratedStore()
        guard let discovery = try store.ociReferrers.loadDiscovery(
            id: discoveryID
        ),
        discovery.complete,
        discovery.subjectDigest == binding.digest,
        let graph = try store.ociReferrers.loadGraph(
            discoveryID: discoveryID
        ),
        graph.discovery.subjectDigest.canonicalValue == binding.digest else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Trust verification requires one complete Gate 6 graph for the exact locked image digest."
            )
        }

        let subjectManifest = try secureRead(
            path: subjectManifestPath,
            maximumBytes: CosignImageTrustVerifier.maximumSubjectBytes,
            role: "subject manifest"
        )
        guard sha256(subjectManifest) == String(binding.digest.dropFirst(7))
        else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Subject manifest bytes do not match the exact locked image digest."
            )
        }
        let bundles: [SigstoreBundleEvidence]
        do {
            bundles = try ImageTrustEvidenceExtractor.bundles(from: graph)
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The verified Gate 6 graph does not contain exact supported Sigstore bundle evidence."
            )
        }

        let timestamp = hostwrightTimestamp()
        let group = try acquireVerificationGroup(
            store: store,
            projectID: binding.projectID,
            serviceName: serviceName,
            descriptorDigest: binding.digest,
            policySHA256: mapping.material.policySHA256,
            discoveryID: discovery.id,
            graphSHA256: discovery.graphSHA256,
            subjectManifestSHA256: sha256(subjectManifest),
            timestamp: timestamp
        )
        let result: ImageTrustVerificationResult
        let record: ImageTrustVerificationRecord
        do {
            result = try environment.imageTrustVerification(
                cosignPath,
                subjectManifest,
                binding.digest,
                bundles,
                mapping.policy
            )
            _ = try store.imageTrust.cacheSubjectManifest(
                ImageTrustSubjectManifestRecord(
                    registryEndpoint: discovery.registryEndpoint,
                    repository: discovery.repository,
                    descriptorDigest: binding.digest,
                    payload: subjectManifest,
                    payloadSHA256: sha256(subjectManifest),
                    observedAt: timestamp
                )
            )
            record = try store.imageTrust.recordVerification(
                ImageTrustVerificationRecord(
                    projectID: binding.projectID,
                    serviceName: serviceName,
                    descriptorDigest: binding.digest,
                    policySHA256: mapping.material.policySHA256,
                    evidenceGraphSHA256: discovery.graphSHA256,
                    evidenceDiscoveryID: discovery.id,
                    trustedRootSHA256:
                        mapping.material.trustedRootSHA256 ??
                        sha256(Data()),
                    verifierVersion: result.verifierVersion,
                    matchedAuthorityIDs:
                        result.matchedAuthorityIDs,
                    threshold: result.threshold,
                    outcome: result.outcome.rawValue,
                    operationGroupID: group.id,
                    createdAt: timestamp
                )
            )
            try appendEvent(
                store: store,
                timestamp: timestamp,
                type:
                    "image.trust.verification." +
                    result.outcome.rawValue,
                projectID: binding.projectID,
                serviceName: serviceName,
                payload: [
                    "descriptorDigest": binding.digest,
                    "policySHA256":
                        mapping.material.policySHA256,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "evidenceDiscoveryID": discovery.id,
                    "matchedAuthorityIDs":
                        result.matchedAuthorityIDs,
                    "threshold": result.threshold,
                    "verifierVersion":
                        result.verifierVersion,
                    "verifierSHA256":
                        result.verifierSHA256,
                    "bundleDigests": result.bundleDigests
                ]
            )
            try store.operationGroups.finish(
                groupID: group.id,
                status: result.outcome == .passed
                    ? .succeeded : .failed,
                checkpoint: result.outcome == .passed
                    ? "verification-observed"
                    : "threshold-not-met",
                manualRecoveryHintRedacted:
                    result.outcome == .passed ? "" :
                    "Obtain sufficient exact signature evidence and run a new verification.",
                updatedAt: hostwrightTimestamp(),
                metadataJSONRedacted:
                    #"{"contract":"hostwright.dev/image-trust/v1"}"#
            )
        } catch {
            try? store.operationGroups.finish(
                groupID: group.id,
                status: .failed,
                checkpoint: "verification-failed",
                manualRecoveryHintRedacted:
                    "Correct the exact verifier or evidence and run a new verification.",
                updatedAt: hostwrightTimestamp(),
                metadataJSONRedacted:
                    #"{"contract":"hostwright.dev/image-trust/v1"}"#
            )
            throw error
        }
        let rendered = render(
            operation: "verify",
            status: record.outcome,
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: record.descriptorDigest,
            policySHA256: record.policySHA256,
            details: [
                "discoveryID": record.evidenceDiscoveryID,
                "evidenceGraphSHA256": record.evidenceGraphSHA256,
                "matchedAuthorityIDs": record.matchedAuthorityIDs,
                "threshold": record.threshold,
                "verifierVersion": record.verifierVersion,
                "operationGroupID": group.id
            ]
        )
        guard result.outcome == .passed else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image trust authority threshold was not met. Verification evidence was recorded; no runtime mutation was attempted."
            )
        }
        return rendered
    }

    private func status(
        manifestPath: String,
        requestedServiceName: String?
    ) throws -> CLIRunResult {
        let manifest = try validatedManifest(at: manifestPath)
        let mapping = try ImageTrustPolicyMapping.map(manifest)
        let serviceName = try ImageTrustPolicyMapping.selectService(
            requestedServiceName,
            manifest: manifest
        )
        let binding = try serviceBinding(
            named: serviceName,
            manifest: manifest
        )
        let store = try migratedStore()
        let records = try store.imageTrust.loadVerifications(
            projectID: binding.projectID,
            serviceName: serviceName,
            descriptorDigest: binding.digest
        )
        let activeException = try store.imageTrust.activeException(
            projectID: binding.projectID,
            serviceName: serviceName,
            descriptorDigest: binding.digest,
            policySHA256: mapping.material.policySHA256,
            currentTimestamp: hostwrightTimestamp()
        )
        let applicable = records.filter {
            $0.policySHA256 == mapping.material.policySHA256
        }
        let latest = applicable.last
        return render(
            operation: "status",
            status: latest?.outcome ??
                (activeException == nil ? "unverified" : "exception-active"),
            projectID: binding.projectID,
            serviceName: serviceName,
            descriptorDigest: binding.digest,
            policySHA256: mapping.material.policySHA256,
            details: [
                "verificationCount": applicable.count,
                "latestVerification": latest.map(verificationObject)
                    ?? NSNull(),
                "activeException": activeException.map(exceptionObject)
                    ?? NSNull()
            ]
        )
    }

    private func grantException(
        approvalRecordPath: String,
        manifestPath: String
    ) throws -> CLIRunResult {
        let approval = try ImageTrustExceptionApproval.parse(
            secureRead(
                path: approvalRecordPath,
                maximumBytes: ImageTrustExceptionApproval.maximumBytes,
                role: "trust exception approval"
            )
        )
        let manifest = try validatedManifest(at: manifestPath)
        let mapping = try ImageTrustPolicyMapping.map(manifest)
        let binding = try serviceBinding(
            named: approval.serviceName,
            manifest: manifest
        )
        guard approval.projectID == binding.projectID,
              approval.descriptorDigest == binding.digest else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Trust exception approval does not match the exact manifest project, service, and image digest."
            )
        }
        let store = try migratedStore()
        let record = try store.imageTrust.recordException(
            ImageTrustExceptionRecord(
                projectID: approval.projectID,
                serviceName: approval.serviceName,
                descriptorDigest: approval.descriptorDigest,
                policySHA256: mapping.material.policySHA256,
                reason: approval.reason,
                approver: approval.approver,
                approvedAt: approval.approvedAt,
                expiresAt: approval.expiresAt,
                idempotencyKey: approval.idempotencyKey
            )
        )
        let timestamp = hostwrightTimestamp()
        try appendEvent(
            store: store,
            timestamp: timestamp,
            type: "image.trust.exception.granted",
            projectID: record.projectID,
            serviceName: record.serviceName,
            payload: exceptionObject(record)
        )
        return render(
            operation: "grant-exception",
            status: "granted",
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: record.descriptorDigest,
            policySHA256: record.policySHA256,
            details: ["exception": exceptionObject(record)]
        )
    }

    private func revokeException(
        exceptionID: String
    ) throws -> CLIRunResult {
        let store = try migratedStore()
        guard let record = try store.imageTrust.loadExceptions()
            .first(where: { $0.id == exceptionID }) else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact image trust exception was not found."
            )
        }
        let timestamp = hostwrightTimestamp()
        guard try store.imageTrust.revokeException(
            idempotencyKey: record.idempotencyKey,
            revokedAt: timestamp
        ) else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact active image trust exception could not be revoked."
            )
        }
        try appendEvent(
            store: store,
            timestamp: timestamp,
            type: "image.trust.exception.revoked",
            projectID: record.projectID,
            serviceName: record.serviceName,
            payload: [
                "exceptionID": record.id,
                "descriptorDigest": record.descriptorDigest,
                "policySHA256": record.policySHA256,
                "revokedAt": timestamp
            ]
        )
        return render(
            operation: "revoke-exception",
            status: "revoked",
            projectID: record.projectID,
            serviceName: record.serviceName,
            descriptorDigest: record.descriptorDigest,
            policySHA256: record.policySHA256,
            details: [
                "exceptionID": record.id,
                "revokedAt": timestamp
            ]
        )
    }

    private func validatedManifest(
        at path: String
    ) throws -> HostwrightManifest {
        let text = try hostwrightReadManifestText(
            path: path,
            environment: environment
        )
        return try hostwrightValidatedManifest(
            text: text,
            teamProfilePath: nil,
            environment: environment
        ).manifest
    }

    private func serviceBinding(
        named serviceName: String,
        manifest: HostwrightManifest
    ) throws -> (
        projectID: String,
        digest: String
    ) {
        guard let project = manifest.project,
              let service = manifest.services.first(where: {
                  $0.name == serviceName
              }),
              let image = service.image,
              let separator = image.lastIndex(of: "@") else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "Image trust requires one exact digest-pinned service image."
            )
        }
        let digest = String(image[image.index(after: separator)...])
            .lowercased()
        guard digest.range(
            of: #"^sha256:[a-f0-9]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "Image trust requires a canonical sha256 image digest."
            )
        }
        return ("project-\(project)", digest)
    }

    private func migratedStore() throws -> SQLiteStateStore {
        let store = SQLiteStateStore(
            configuration: try hostwrightStateStoreConfiguration(
                explicitPath: stateDatabasePath,
                environment: environment
            )
        )
        try store.migrate()
        return store
    }

    private func acquireVerificationGroup(
        store: SQLiteStateStore,
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        discoveryID: String,
        graphSHA256: String,
        subjectManifestSHA256: String,
        timestamp: String
    ) throws -> OperationGroupRecord {
        let intent: [String: Any] = [
            "apiVersion": "hostwright.dev/image-trust/v1",
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": descriptorDigest,
            "policySHA256": policySHA256,
            "discoveryID": discoveryID,
            "graphSHA256": graphSHA256,
            "subjectManifestSHA256": subjectManifestSHA256
        ]
        let intentData = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let planSHA256 = sha256(intentData)
        let id = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-trust-verification",
            projectID: projectID,
            serviceName: serviceName,
            plannedActionType: "verify",
            status: .active,
            groupIdempotencyKey: planSHA256,
            planHash: planSHA256,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-registry-trust",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 300,
                to: timestamp
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "A failed or interrupted read-only trust verification may be rerun with the exact inputs.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-trust/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted:
                String(decoding: intentData, as: UTF8.self),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: timestamp
        )
        guard let value = acquired.acquired else {
            throw HostwrightDiagnostic(
                code: .partialFailure,
                message: "An exact image trust verification is already active. No runtime mutation was attempted."
            )
        }
        return value
    }

    private func secureRead(
        path: String,
        maximumBytes: Int,
        role: String
    ) throws -> Data {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "Could not safely read the \(role)."
            )
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == getuid() || metadata.st_uid == 0,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size > 0,
              metadata.st_size <= maximumBytes else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The \(role) failed secure ownership, type, or size checks."
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw HostwrightDiagnostic(
                    code: .fileIOFailed,
                    message: "Could not safely read the \(role)."
                )
            }
            data.append(buffer, count: count)
        }
        guard data.count == metadata.st_size else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The \(role) changed while it was being read."
            )
        }
        return data
    }

    private func appendEvent(
        store: SQLiteStateStore,
        timestamp: String,
        type: String,
        projectID: String,
        serviceName: String,
        payload: [String: Any]
    ) throws {
        var eventPayload = payload
        eventPayload["projectID"] = projectID
        let data = try JSONSerialization.data(
            withJSONObject: eventPayload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= 64 * 1_024 else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image trust audit evidence exceeded its bound."
            )
        }
        let indexedProjectID = try? store.desiredStates.loadProject(
            id: projectID
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: timestamp,
                severity: .info,
                type: type,
                source: "hostwright.registry.trust",
                projectID: indexedProjectID == nil ? nil : projectID,
                serviceName: serviceName,
                runtimeAdapter: nil,
                message: "Image trust evidence changed.",
                payloadJSONRedacted: String(decoding: data, as: UTF8.self)
            )
        ])
    }

    private func verificationObject(
        _ record: ImageTrustVerificationRecord
    ) -> [String: Any] {
        [
            "outcome": record.outcome,
            "createdAt": record.createdAt,
            "discoveryID": record.evidenceDiscoveryID,
            "evidenceGraphSHA256": record.evidenceGraphSHA256,
            "matchedAuthorityIDs": record.matchedAuthorityIDs,
            "threshold": record.threshold,
            "verifierVersion": record.verifierVersion,
            "operationGroupID": record.operationGroupID
        ]
    }

    private func exceptionObject(
        _ record: ImageTrustExceptionRecord
    ) -> [String: Any] {
        [
            "id": record.id,
            "descriptorDigest": record.descriptorDigest,
            "policySHA256": record.policySHA256,
            "approver": record.approver,
            "approvedAt": record.approvedAt,
            "expiresAt": record.expiresAt,
            "revokedAt": record.revokedAt.map { $0 as Any } ?? NSNull()
        ]
    }

    private func render(
        operation: String,
        status: String,
        projectID: String,
        serviceName: String,
        descriptorDigest: String,
        policySHA256: String,
        details: [String: Any]
    ) -> CLIRunResult {
        let object: [String: Any] = [
            "apiVersion": "hostwright.dev/image-trust/v1",
            "operation": operation,
            "status": status,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": descriptorDigest,
            "policySHA256": policySHA256,
            "details": details
        ]
        if output == .json {
            let data = try! JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return CLIRunResult(
                standardOutput:
                    String(decoding: data, as: UTF8.self) + "\n"
            )
        }
        return CLIRunResult(
            standardOutput:
                "Image trust \(operation): \(status)\n" +
                "Service: \(serviceName)\n" +
                "Digest: \(descriptorDigest)\n"
        )
    }

    private func trustDiagnostic(
        _ error: ImageTrustVerifierError
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .registryInvalid,
            message: "\(error.description) No runtime mutation was attempted."
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
