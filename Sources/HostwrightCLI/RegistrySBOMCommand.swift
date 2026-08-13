import CryptoKit
import Darwin
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry
import HostwrightRuntime
import HostwrightState

struct RegistrySBOMCommandRunner {
    let action: RegistrySBOMCLIAction
    let stateDatabasePath: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment
    let cancellation: SecureSubprocessCancellation

    init(
        action: RegistrySBOMCLIAction,
        stateDatabasePath: String?,
        output: CLIOutputFormat,
        environment: CLIEnvironment,
        cancellation: SecureSubprocessCancellation =
            SecureSubprocessCancellation()
    ) {
        self.action = action
        self.stateDatabasePath = stateDatabasePath
        self.output = output
        self.environment = environment
        self.cancellation = cancellation
    }

    func run() throws -> CLIRunResult {
        do {
            switch action {
            case .generate(
                let archivePath,
                let manifestPath,
                let serviceName,
                let server,
                let repository,
                let format,
                let provenanceDescriptor,
                let provenanceReferrer
            ):
                return try generate(
                    archivePath: archivePath,
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName,
                    server: server,
                    repository: repository,
                    format: try formatValue(format),
                    provenanceDescriptorDigest:
                        provenanceDescriptor,
                    provenanceReferrerDigest:
                        provenanceReferrer
                )
            case .ingest(
                let discoveryID,
                let manifestPath,
                let serviceName
            ):
                return try ingest(
                    discoveryID: discoveryID,
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName
                )
            case .query(let manifestPath, let serviceName):
                return try query(
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName
                )
            case .export(
                let manifestPath,
                let serviceName,
                let format,
                let outputPath
            ):
                return try export(
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName,
                    format: try formatValue(format),
                    outputPath: outputPath
                )
            case .resume(
                let operationGroupID,
                let confirmationPlanSHA256
            ):
                return try resume(
                    operationGroupID: operationGroupID,
                    confirmationPlanSHA256:
                        confirmationPlanSHA256
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch ImageSBOMError.cancelled {
            throw HostwrightDiagnostic(
                code: .partialFailure,
                message: "The image SBOM operation was cancelled at a bounded checkpoint and can be resumed with its exact confirmation plan."
            )
        } catch let error as ImageSBOMError {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "\(error.description) No runtime mutation was attempted."
            )
        } catch let error as StateStoreError {
            throw HostwrightDiagnostic(
                code: .stateStoreUnavailable,
                message: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        } catch {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: RuntimeRedactionPolicy.default.redact(
                    String(describing: error)
                )
            )
        }
    }

    static func exportFailureStatus(
        outputApplied: Bool
    ) -> OperationGroupStatus {
        outputApplied ? .interrupted : .failed
    }

    private func generate(
        archivePath: String,
        manifestPath: String,
        requestedServiceName: String?,
        server: String,
        repository: String,
        format: ImageSBOMFormat,
        provenanceDescriptorDigest: String?,
        provenanceReferrerDigest: String?,
        createdAt: String? = nil,
        resumingGroup: OperationGroupRecord? = nil
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        guard context.policy.formats.contains(format) else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The requested SBOM format is not allowed by the exact manifest policy."
            )
        }
        let endpoint = try RegistryEndpoint(server)
        let repository = try OCIRepositoryName(repository)
        let subject = try OCIContentDigest(
            context.descriptorDigest
        )
        let provenanceDescriptor = try provenanceDescriptorDigest
            .map(OCIContentDigest.init)
        let provenanceReferrer = try provenanceReferrerDigest
            .map(OCIContentDigest.init)
        let store = try migratedStore()
        let generationTimestamp = createdAt ?? hostwrightTimestamp()
        let group: OperationGroupRecord
        if let resumingGroup {
            try validate(
                resumingGroup: resumingGroup,
                operation: "generate",
                context: context
            )
            group = resumingGroup
        } else {
            group = try acquireGroup(
                store: store,
                operation: "generate",
                context: context,
                details: [
                    "archivePath": archivePath,
                    "archivePathSHA256":
                        sha256(Data(archivePath.utf8)),
                    "manifestPath": manifestPath,
                    "requestedServiceName":
                        requestedServiceName ?? NSNull(),
                    "endpoint": endpoint.canonicalURLString,
                    "repository": repository.value,
                    "format": format.rawValue,
                    "createdAt": generationTimestamp,
                    "provenanceDescriptorDigest":
                        provenanceDescriptor?.canonicalValue
                            ?? NSNull(),
                    "provenanceReferrerDigest":
                        provenanceReferrer?.canonicalValue
                            ?? NSNull()
                ]
            )
        }
        let mutationFence = try hostwrightAcquireExactOperationMutationFence(
            store: store,
            group: group
        )
        defer { mutationFence.release() }
        do {
            let generated = try OCIImageArchiveSBOMGenerator()
                .generate(
                    archivePath: archivePath,
                    expectedSubjectDigest: subject,
                    format: format,
                    createdAt: generationTimestamp,
                    cancellation: cancellation
                )
            let artifact = try ImageSBOMArtifact.make(
                documentPayload: generated.payload,
                expectedFormat: format,
                subjectDescriptor:
                    generated.inventory.subjectDescriptor,
                endpoint: endpoint,
                repository: repository,
                provenanceDescriptorDigest:
                    provenanceDescriptor,
                provenanceReferrerDigest: provenanceReferrer
            )
            let discovery = try store.ociReferrers.saveGraph(
                artifact.graph,
                observedAt: hostwrightTimestamp()
            )
            try finish(
                store: store,
                group: group,
                status: .succeeded,
                checkpoint: "generated-graph-observed",
                verification: [
                    "discoveryID": discovery.id,
                    "graphSHA256": discovery.graphSHA256,
                    "referrerDigest":
                        artifact.rootDescriptor.digest.canonicalValue,
                    "documentDigest":
                        artifact.document.documentDigest
                            .canonicalValue,
                    "componentCount":
                        artifact.document.components.count
                ]
            )
            return render(
                operation: "generate",
                status: "generated",
                context: context,
                details: [
                    "format": format.rawValue,
                    "discoveryID": discovery.id,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "referrerDigest":
                        artifact.rootDescriptor.digest.canonicalValue,
                    "documentDigest":
                        artifact.document.documentDigest
                            .canonicalValue,
                    "componentCount":
                        artifact.document.components.count,
                    "operationGroupID": group.id,
                    "confirmationPlanSHA256": group.planHash,
                    "next":
                        "Publish the exact generated discovery with registry referrers publish, then fetch and ingest the verified target graph."
                ]
            )
        } catch ImageSBOMError.cancelled {
            try? interrupt(store: store, group: group)
            throw ImageSBOMError.cancelled
        } catch {
            try? fail(store: store, group: group)
            throw error
        }
    }

    private func ingest(
        discoveryID: String,
        manifestPath: String,
        requestedServiceName: String?,
        resumingGroup: OperationGroupRecord? = nil
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        let store = try migratedStore()
        guard let discovery = try store.ociReferrers
            .loadDiscovery(id: discoveryID),
        let graph = try store.ociReferrers.loadGraph(
            discoveryID: discoveryID
        ),
        discovery.complete,
        discovery.subjectDigest == context.descriptorDigest else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact complete verified OCI graph for this image was not found."
            )
        }
        let evidence = try ImageSBOMEvidenceExtractor.extract(
            from: graph,
            expectedSubjectDigest: try OCIContentDigest(
                context.descriptorDigest
            ),
            allowedFormats: context.policy.formats
        )
        let existing = try store.imageSBOM.loadRecords(
            projectID: context.projectID,
            serviceName: context.serviceName,
            descriptorDigest: context.descriptorDigest,
            policySHA256: context.policy.policySHA256
        )
        let pending = evidence.filter { item in
            !existing.contains {
                $0.documentDigest ==
                    item.document.documentDigest.canonicalValue &&
                $0.sbomReferrerDigest ==
                    item.rootDescriptor.digest.canonicalValue &&
                $0.evidenceDiscoveryID == discoveryID
            }
        }
        if pending.isEmpty, resumingGroup == nil {
            return render(
                operation: "ingest",
                status: "already-ingested",
                context: context,
                details: [
                    "discoveryID": discoveryID,
                    "recordCount": existing.count
                ]
            )
        }
        let group: OperationGroupRecord
        if let resumingGroup {
            try validate(
                resumingGroup: resumingGroup,
                operation: "ingest",
                context: context
            )
            group = resumingGroup
        } else {
            group = try acquireGroup(
                store: store,
                operation: "ingest",
                context: context,
                details: [
                    "manifestPath": manifestPath,
                    "requestedServiceName":
                        requestedServiceName ?? NSNull(),
                    "discoveryID": discoveryID,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "referrerDigests": pending.map {
                        $0.rootDescriptor.digest.canonicalValue
                    }.sorted()
                ]
            )
        }
        let mutationFence = try hostwrightAcquireExactOperationMutationFence(
            store: store,
            group: group
        )
        defer { mutationFence.release() }
        do {
            var recorded: [ImageSBOMRecord] = []
            for item in pending {
                let record = try store.imageSBOM.record(
                    ImageSBOMRecord(
                        projectID: context.projectID,
                        serviceName: context.serviceName,
                        descriptorDigest:
                            context.descriptorDigest,
                        policySHA256:
                            context.policy.policySHA256,
                        format: try stateFormat(
                            item.document.format
                        ),
                        documentDigest:
                            item.document.documentDigest
                                .canonicalValue,
                        documentMediaType:
                            item.document.format.layerMediaType,
                        evidenceDiscoveryID: discoveryID,
                        evidenceGraphSHA256:
                            discovery.graphSHA256,
                        sbomReferrerDigest:
                            item.rootDescriptor.digest
                                .canonicalValue,
                        provenanceDescriptorDigest:
                            item.provenanceDescriptorDigest?
                                .canonicalValue,
                        provenanceReferrerDigest:
                            item.provenanceReferrerDigest?
                                .canonicalValue,
                        componentCount:
                            item.document.components.count,
                        normalizedComponentsSHA256:
                            item.document
                                .normalizedComponentsSHA256,
                        operationGroupID: group.id,
                        createdAt: hostwrightTimestamp()
                    )
                )
                recorded.append(record)
            }
            try finish(
                store: store,
                group: group,
                status: .succeeded,
                checkpoint: "binding-observed",
                verification: [
                    "recordCount": recorded.count,
                    "documentDigests": recorded.map {
                        $0.documentDigest
                    }.sorted()
                ]
            )
            return render(
                operation: "ingest",
                status: "verified",
                context: context,
                details: [
                    "discoveryID": discoveryID,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "recordCount": recorded.count,
                    "records": recorded.map(recordObject),
                    "operationGroupID": group.id,
                    "confirmationPlanSHA256": group.planHash
                ]
            )
        } catch {
            try? fail(store: store, group: group)
            throw error
        }
    }

    private func query(
        manifestPath: String,
        requestedServiceName: String?
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        let store = try migratedStore()
        let persisted = try store.imageSBOM.loadRecords(
            projectID: context.projectID,
            serviceName: context.serviceName,
            descriptorDigest: context.descriptorDigest,
            policySHA256: context.policy.policySHA256
        )
        let records = try verifiedRecords(
            persisted,
            context: context,
            store: store
        )
        let satisfied = context.policy.formats.allSatisfy {
            format in
            records.contains {
                $0.format.rawValue == format.rawValue
            }
        }
        let status: String
        if satisfied {
            status = "satisfied"
        } else if context.policy.requirement == .required {
            status = "required-missing"
        } else {
            status = "optional-missing"
        }
        return render(
            operation: "query",
            status: status,
            context: context,
            details: [
                "recordCount": records.count,
                "records": records.map(recordObject),
                "invalidOrUnavailableRecordCount":
                    persisted.count - records.count,
                "missingFormats": context.policy.formats
                    .filter { format in
                        !records.contains {
                            $0.format.rawValue == format.rawValue
                        }
                    }.map(\.rawValue).sorted()
            ]
        )
    }

    private func export(
        manifestPath: String,
        requestedServiceName: String?,
        format: ImageSBOMFormat,
        outputPath: String,
        resumingGroup: OperationGroupRecord? = nil
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        guard context.policy.formats.contains(format) else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "The requested export format is not allowed by the exact manifest policy."
            )
        }
        let store = try migratedStore()
        let persisted = try store.imageSBOM.loadRecords(
            projectID: context.projectID,
            serviceName: context.serviceName,
            descriptorDigest: context.descriptorDigest,
            policySHA256: context.policy.policySHA256
        )
        let records = try verifiedRecords(
            persisted,
            context: context,
            store: store
        )
        guard let record = records.last(where: {
            $0.format.rawValue == format.rawValue
        }),
        let graph = try store.ociReferrers.loadGraph(
            discoveryID: record.evidenceDiscoveryID
        ),
        let object = graph.objects.first(where: {
            $0.digest.canonicalValue == record.documentDigest
        }),
        object.mediaType == record.documentMediaType,
        try object.digest.matches(object.payload) else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The exact verified SBOM document is unavailable for export."
            )
        }
        let group: OperationGroupRecord
        if let resumingGroup {
            try validate(
                resumingGroup: resumingGroup,
                operation: "export",
                context: context
            )
            group = resumingGroup
        } else {
            group = try acquireGroup(
                store: store,
                operation: "export",
                context: context,
                details: [
                    "manifestPath": manifestPath,
                    "requestedServiceName":
                        requestedServiceName ?? NSNull(),
                    "format": format.rawValue,
                    "documentDigest": record.documentDigest,
                    "outputPath": outputPath,
                    "outputPathSHA256":
                        sha256(Data(outputPath.utf8))
                ]
            )
        }
        let mutationFence = try hostwrightAcquireExactOperationMutationFence(
            store: store,
            group: group
        )
        defer { mutationFence.release() }
        var outputApplied = false
        let successResult = {
            render(
                operation: "export",
                status: "verified",
                context: context,
                details: [
                    "format": format.rawValue,
                    "documentDigest": record.documentDigest,
                    "size": object.payload.count,
                    "outputPath": outputPath,
                    "operationGroupID": group.id,
                    "confirmationPlanSHA256": group.planHash
                ]
            )
        }
        do {
            try writeNewVerified(
                object.payload,
                path: outputPath,
                digest: object.digest,
                allowExactExisting: resumingGroup != nil
            )
            outputApplied = true
            try finish(
                store: store,
                group: group,
                status: .succeeded,
                checkpoint: "export-observed",
                verification: [
                    "documentDigest": record.documentDigest,
                    "size": object.payload.count
                ]
            )
            return successResult()
        } catch {
            if Self.exportFailureStatus(
                outputApplied: outputApplied
            ) == .interrupted {
                if let current = try? store.operationGroups.load(
                    id: group.id
                ),
                current.status == .succeeded {
                    return successResult()
                }
                try? interruptAfterExport(
                    store: store,
                    group: group
                )
            } else {
                try? fail(store: store, group: group)
            }
            throw error
        }
    }

    private func verifiedRecords(
        _ records: [ImageSBOMRecord],
        context: SBOMContext,
        store: SQLiteStateStore
    ) throws -> [ImageSBOMRecord] {
        var verified: [ImageSBOMRecord] = []
        for record in records {
            guard let discovery = try store.ociReferrers
                .loadDiscovery(id: record.evidenceDiscoveryID),
                discovery.complete,
                discovery.subjectDigest == context.descriptorDigest,
                discovery.graphSHA256 ==
                    record.evidenceGraphSHA256,
                let graph = try store.ociReferrers.loadGraph(
                    discoveryID: record.evidenceDiscoveryID
                ),
                let format = ImageSBOMFormat(
                    rawValue: record.format.rawValue
                ),
                let evidence = try? ImageSBOMEvidenceExtractor
                    .extract(
                        from: graph,
                        expectedSubjectDigest:
                            OCIContentDigest(
                                context.descriptorDigest
                            ),
                        allowedFormats: [format]
                    ),
                evidence.contains(where: {
                    $0.document.documentDigest.canonicalValue ==
                        record.documentDigest &&
                    $0.rootDescriptor.digest.canonicalValue ==
                        record.sbomReferrerDigest &&
                    $0.document.components.count ==
                        record.componentCount &&
                    $0.document.normalizedComponentsSHA256 ==
                        record.normalizedComponentsSHA256 &&
                    $0.provenanceDescriptorDigest?
                        .canonicalValue ==
                        record.provenanceDescriptorDigest &&
                    $0.provenanceReferrerDigest?
                        .canonicalValue ==
                        record.provenanceReferrerDigest
                }) else {
                continue
            }
            verified.append(record)
        }
        return verified
    }

    private func resume(
        operationGroupID: String,
        confirmationPlanSHA256: String
    ) throws -> CLIRunResult {
        let store = try migratedStore()
        guard let source = try store.operationGroups.load(
            id: operationGroupID
        ),
        source.groupKind == "image-sbom",
        source.planHash == confirmationPlanSHA256 else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image SBOM recovery requires the exact operation group and confirmation plan."
            )
        }
        let intentData = Data(source.intentJSONRedacted.utf8)
        guard let intent = try JSONSerialization.jsonObject(
                  with: intentData
              ) as? [String: Any],
              intent["apiVersion"] as? String ==
                "hostwright.dev/image-sbom/v1",
              let operation = intent["operation"] as? String,
              operation == source.plannedActionType,
              intent["projectID"] as? String == source.projectID,
              intent["serviceName"] as? String ==
                source.serviceName else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image SBOM recovery intent failed its exact stored proof."
            )
        }
        let canonicalIntent = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard sha256(canonicalIntent) == source.planHash else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image SBOM recovery intent failed its exact stored proof."
            )
        }
        let now = hostwrightTimestamp()
        let resumed: OperationGroupRecord
        switch source.status {
        case .interrupted:
            resumed = try store.operationGroups.resumeInterrupted(
                groupID: source.id,
                expectedFencingToken: source.fencingToken,
                lockOwner: "hostwright-registry-sbom-recovery",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 300,
                    to: now
                ),
                updatedAt: now
            )
        case .active:
            let recovery =
                try store.operationGroups.reclaimExpiredActive(
                    groupID: source.id,
                    expectedPlanHash: source.planHash,
                    expectedFencingToken: source.fencingToken,
                    lockOwner:
                        "hostwright-registry-sbom-recovery",
                    lockExpiresAt: hostwrightTimestampAdding(
                        seconds: 300,
                        to: now
                    ),
                    currentTimestamp: now
                )
            switch recovery {
            case .reclaimed(let group):
                resumed = group
            case .activeUnexpired:
                throw HostwrightDiagnostic(
                    code: .partialFailure,
                    message: "The exact image SBOM operation lease is still active; recovery refused to race it."
                )
            }
        case .succeeded, .failed:
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Only interrupted or expired active image SBOM operations can be resumed."
            )
        }
        switch operation {
        case "generate":
            try requireIntentKeys(
                intent,
                [
                    "apiVersion", "operation", "projectID",
                    "serviceName", "descriptorDigest",
                    "policySHA256", "archivePath",
                    "archivePathSHA256", "manifestPath",
                    "requestedServiceName", "endpoint",
                    "repository", "format", "createdAt",
                    "provenanceDescriptorDigest",
                    "provenanceReferrerDigest"
                ]
            )
            let archivePath = try intentString(
                intent, "archivePath"
            )
            let archivePathSHA256 = try intentString(
                intent, "archivePathSHA256"
            )
            guard sha256(Data(archivePath.utf8)) ==
                    archivePathSHA256 else {
                throw invalidRecoveryIntent()
            }
            return try generate(
                archivePath: archivePath,
                manifestPath: try intentString(
                    intent, "manifestPath"
                ),
                requestedServiceName: try optionalIntentString(
                    intent, "requestedServiceName"
                ),
                server: try intentString(intent, "endpoint"),
                repository: try intentString(
                    intent, "repository"
                ),
                format: try formatValue(
                    intentString(intent, "format")
                ),
                provenanceDescriptorDigest:
                    try optionalIntentString(
                        intent,
                        "provenanceDescriptorDigest"
                    ),
                provenanceReferrerDigest:
                    try optionalIntentString(
                        intent,
                        "provenanceReferrerDigest"
                    ),
                createdAt: try intentString(intent, "createdAt"),
                resumingGroup: resumed
            )
        case "ingest":
            try requireIntentKeys(
                intent,
                [
                    "apiVersion", "operation", "projectID",
                    "serviceName", "descriptorDigest",
                    "policySHA256", "manifestPath",
                    "requestedServiceName", "discoveryID",
                    "evidenceGraphSHA256", "referrerDigests"
                ]
            )
            return try ingest(
                discoveryID: try intentString(
                    intent, "discoveryID"
                ),
                manifestPath: try intentString(
                    intent, "manifestPath"
                ),
                requestedServiceName: try optionalIntentString(
                    intent, "requestedServiceName"
                ),
                resumingGroup: resumed
            )
        case "export":
            try requireIntentKeys(
                intent,
                [
                    "apiVersion", "operation", "projectID",
                    "serviceName", "descriptorDigest",
                    "policySHA256", "manifestPath",
                    "requestedServiceName", "format",
                    "documentDigest", "outputPath",
                    "outputPathSHA256"
                ]
            )
            let outputPath = try intentString(
                intent, "outputPath"
            )
            let outputPathSHA256 = try intentString(
                intent, "outputPathSHA256"
            )
            guard sha256(Data(outputPath.utf8)) ==
                    outputPathSHA256 else {
                throw invalidRecoveryIntent()
            }
            return try export(
                manifestPath: try intentString(
                    intent, "manifestPath"
                ),
                requestedServiceName: try optionalIntentString(
                    intent, "requestedServiceName"
                ),
                format: try formatValue(
                    intentString(intent, "format")
                ),
                outputPath: outputPath,
                resumingGroup: resumed
            )
        default:
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "The stored image SBOM operation is not resumable."
            )
        }
    }

    private func validate(
        resumingGroup: OperationGroupRecord,
        operation: String,
        context: SBOMContext
    ) throws {
        guard resumingGroup.groupKind == "image-sbom",
              resumingGroup.status == .active,
              resumingGroup.plannedActionType == operation,
              resumingGroup.projectID == context.projectID,
              resumingGroup.serviceName == context.serviceName,
              let data = resumingGroup.intentJSONRedacted.data(
                  using: .utf8
              ),
              let intent = try JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              intent["descriptorDigest"] as? String ==
                context.descriptorDigest,
              intent["policySHA256"] as? String ==
                context.policy.policySHA256 else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image SBOM recovery no longer matches the exact manifest policy and image digest."
            )
        }
    }

    private func requireIntentKeys(
        _ intent: [String: Any],
        _ expected: Set<String>
    ) throws {
        guard Set(intent.keys) == expected else {
            throw invalidRecoveryIntent()
        }
    }

    private func intentString(
        _ intent: [String: Any],
        _ key: String
    ) throws -> String {
        guard let value = intent[key] as? String,
              !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw invalidRecoveryIntent()
        }
        return value
    }

    private func optionalIntentString(
        _ intent: [String: Any],
        _ key: String
    ) throws -> String? {
        if intent[key] is NSNull {
            return nil
        }
        return try intentString(intent, key)
    }

    private func invalidRecoveryIntent() -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .registryInvalid,
            message: "The stored image SBOM recovery intent is invalid."
        )
    }

    private func policyContext(
        manifestPath: String,
        requestedServiceName: String?
    ) throws -> SBOMContext {
        let text = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let manifest = try hostwrightValidatedManifest(
            text: text,
            teamProfilePath: nil,
            environment: environment
        ).manifest
        let policy = try ImageSBOMPolicyMapping.map(manifest)
        let serviceName = try ImageSBOMPolicyMapping.selectService(
            requestedServiceName,
            manifest: manifest
        )
        guard let project = manifest.project,
              let service = manifest.services.first(
                  where: { $0.name == serviceName }
              ),
              let image = service.image,
              let separator = image.lastIndex(of: "@") else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "Image SBOM policy requires an exact digest-pinned service image."
            )
        }
        let digest = String(
            image[image.index(after: separator)...]
        ).lowercased()
        guard digest.range(
            of: "^sha256:[a-f0-9]{64}$",
            options: .regularExpression
        ) != nil else {
            throw HostwrightDiagnostic(
                code: .manifestValidationFailed,
                message: "Image SBOM policy requires a canonical sha256 image digest."
            )
        }
        return SBOMContext(
            projectID: "project-\(project)",
            serviceName: serviceName,
            descriptorDigest: digest,
            policy: policy
        )
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

    private func acquireGroup(
        store: SQLiteStateStore,
        operation: String,
        context: SBOMContext,
        details: [String: Any]
    ) throws -> OperationGroupRecord {
        var intent = details
        intent["apiVersion"] = "hostwright.dev/image-sbom/v1"
        intent["operation"] = operation
        intent["projectID"] = context.projectID
        intent["serviceName"] = context.serviceName
        intent["descriptorDigest"] = context.descriptorDigest
        intent["policySHA256"] = context.policy.policySHA256
        let data = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= 64 * 1_024 else {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "Image SBOM durable intent exceeded its bound."
            )
        }
        let plan = sha256(data)
        let timestamp = hostwrightTimestamp()
        let id = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: "image-sbom",
            projectID: context.projectID,
            serviceName: context.serviceName,
            plannedActionType: operation,
            status: .active,
            groupIdempotencyKey: plan,
            planHash: plan,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-registry-sbom",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 300,
                to: timestamp
            ),
            rollbackAvailable: operation == "export",
            manualRecoveryHintRedacted:
                "Rerun the exact image SBOM operation; generated and ingested content is immutable and idempotent.",
            createdAt: timestamp,
            updatedAt: timestamp,
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted: String(decoding: data, as: UTF8.self),
            compensationJSONRedacted:
                operation == "export"
                    ? #"[{"deleteOnlyExactNewOutput":true}]"#
                    : "[]",
            verificationJSONRedacted: "{}"
        )
        let acquired = try store.operationGroups.acquire(
            group,
            currentTimestamp: timestamp
        )
        guard let value = acquired.acquired else {
            throw HostwrightDiagnostic(
                code: .partialFailure,
                message: "An exact image SBOM operation is already active."
            )
        }
        return value
    }

    private func finish(
        store: SQLiteStateStore,
        group: OperationGroupRecord,
        status: OperationGroupStatus,
        checkpoint: String,
        verification: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: verification,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: checkpoint,
            verificationJSONRedacted:
                String(decoding: data, as: UTF8.self),
            updatedAt: hostwrightTimestamp()
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: status,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: "",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
    }

    private func fail(
        store: SQLiteStateStore,
        group: OperationGroupRecord
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .failed,
            checkpoint: "failed-no-runtime-effect",
            manualRecoveryHintRedacted:
                "Correct the exact SBOM input and run a new operation.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
    }

    private func interrupt(
        store: SQLiteStateStore,
        group: OperationGroupRecord
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "cancelled-at-bounded-checkpoint",
            manualRecoveryHintRedacted:
                "Resume with the exact operation group and confirmation plan.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
    }

    private func interruptAfterExport(
        store: SQLiteStateStore,
        group: OperationGroupRecord
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: "export-written-finalization-interrupted",
            manualRecoveryHintRedacted:
                "Resume with the exact operation group and confirmation plan to verify and adopt the exact output file.",
            updatedAt: hostwrightTimestamp(),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-sbom/v1"}"#
        )
    }

    private func writeNewVerified(
        _ data: Data,
        path: String,
        digest: OCIContentDigest,
        allowExactExisting: Bool
    ) throws {
        let descriptor = Darwin.open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        if descriptor < 0, errno == EEXIST, allowExactExisting {
            try verifyExistingExport(
                path: path,
                expectedData: data,
                digest: digest
            )
            return
        }
        guard descriptor >= 0 else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The SBOM export path must be a new exact file."
            )
        }
        var complete = false
        defer {
            Darwin.close(descriptor)
            if !complete { Darwin.unlink(path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw HostwrightDiagnostic(
                        code: .fileIOFailed,
                        message: "Could not write the exact SBOM export."
                    )
                }
                offset += count
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "Could not durably persist the exact SBOM export."
            )
        }
        let observed = try Data(contentsOf: URL(fileURLWithPath: path))
        guard try digest.matches(observed) else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The persisted SBOM export failed digest verification."
            )
        }
        complete = true
    }

    private func verifyExistingExport(
        path: String,
        expectedData: Data,
        digest: OCIContentDigest
    ) throws {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The existing SBOM export could not be verified."
            )
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              metadata.st_size == expectedData.count else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The existing SBOM export does not match the exact safe output identity."
            )
        }
        var observed = Data(count: expectedData.count)
        let totalBytes = observed.count
        var offset = 0
        while offset < totalBytes {
            let count = observed.withUnsafeMutableBytes { bytes in
                pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    totalBytes - offset,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                throw HostwrightDiagnostic(
                    code: .fileIOFailed,
                    message: "The existing SBOM export could not be read exactly."
                )
            }
            offset += count
        }
        guard observed == expectedData,
              try digest.matches(observed) else {
            throw HostwrightDiagnostic(
                code: .fileIOFailed,
                message: "The existing SBOM export failed exact digest verification."
            )
        }
    }

    private func stateFormat(
        _ format: ImageSBOMFormat
    ) throws -> ImageSBOMDocumentFormat {
        guard let value = ImageSBOMDocumentFormat(
            rawValue: format.rawValue
        ) else {
            throw ImageSBOMError.unsupportedFormat
        }
        return value
    }

    private func formatValue(
        _ value: String
    ) throws -> ImageSBOMFormat {
        guard let format = ImageSBOMFormat(rawValue: value) else {
            throw ImageSBOMError.unsupportedFormat
        }
        return format
    }

    private func recordObject(
        _ record: ImageSBOMRecord
    ) -> [String: Any] {
        [
            "format": record.format.rawValue,
            "documentDigest": record.documentDigest,
            "documentMediaType": record.documentMediaType,
            "discoveryID": record.evidenceDiscoveryID,
            "evidenceGraphSHA256":
                record.evidenceGraphSHA256,
            "referrerDigest": record.sbomReferrerDigest,
            "componentCount": record.componentCount,
            "normalizedComponentsSHA256":
                record.normalizedComponentsSHA256,
            "provenanceDescriptorDigest":
                record.provenanceDescriptorDigest ?? NSNull(),
            "provenanceReferrerDigest":
                record.provenanceReferrerDigest ?? NSNull(),
            "createdAt": record.createdAt
        ]
    }

    private func render(
        operation: String,
        status: String,
        context: SBOMContext,
        details: [String: Any]
    ) -> CLIRunResult {
        let object: [String: Any] = [
            "apiVersion": "hostwright.dev/image-sbom/v1",
            "operation": operation,
            "status": status,
            "projectID": context.projectID,
            "serviceName": context.serviceName,
            "descriptorDigest": context.descriptorDigest,
            "policySHA256": context.policy.policySHA256,
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
                "Image SBOM \(operation): \(status)\n" +
                "Service: \(context.serviceName)\n" +
                "Digest: \(context.descriptorDigest)\n"
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

private struct SBOMContext {
    let projectID: String
    let serviceName: String
    let descriptorDigest: String
    let policy: ImageSBOMPolicyMaterial
}
