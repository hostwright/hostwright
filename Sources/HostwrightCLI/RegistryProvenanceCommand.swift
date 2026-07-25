import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState

struct RegistryProvenanceCommandRunner {
    static let apiVersion = "hostwright.dev/image-provenance/v1"
    static let groupKind = "image-provenance"

    let action: RegistryProvenanceCLIAction
    let stateDatabasePath: String?
    let output: CLIOutputFormat
    let environment: CLIEnvironment
    let cancellation: SecureSubprocessCancellation

    init(
        action: RegistryProvenanceCLIAction,
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
                let recordPath,
                let manifestPath,
                let serviceName,
                let server,
                let repository,
                let signerID,
                let signingKeyReference
            ):
                return try generate(
                    archivePath: archivePath,
                    recordPath: recordPath,
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName,
                    server: server,
                    repository: repository,
                    signerID: signerID,
                    signingKeyReference: signingKeyReference,
                    signingDate: environment.registryDate(),
                    resumingGroup: nil
                )
            case .verify(
                let discoveryID,
                let referrerDigest,
                let manifestPath,
                let serviceName
            ):
                return try verify(
                    discoveryID: discoveryID,
                    referrerDigest: referrerDigest,
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName,
                    verificationDate: environment.registryDate(),
                    resumingGroup: nil
                )
            case .status(let manifestPath, let serviceName):
                return try status(
                    manifestPath: manifestPath,
                    requestedServiceName: serviceName
                )
            case .resume(
                let operationGroupID,
                let confirmationPlanSHA256,
                let signingKeyReference
            ):
                return try resume(
                    operationGroupID: operationGroupID,
                    confirmationPlanSHA256:
                        confirmationPlanSHA256,
                    signingKeyReference: signingKeyReference
                )
            }
        } catch let diagnostic as HostwrightDiagnostic {
            throw diagnostic
        } catch ImageProvenanceError.cancelled {
            throw HostwrightDiagnostic(
                code: .partialFailure,
                message: "The image provenance operation was cancelled at a bounded checkpoint and can be resumed with its exact confirmation plan."
            )
        } catch let error as ImageProvenanceError {
            throw HostwrightDiagnostic(
                code: .registryInvalid,
                message: "\(error.description) No runtime mutation was attempted."
            )
        } catch let error as ImageSBOMError {
            throw HostwrightDiagnostic(
                code: error == .cancelled
                    ? .partialFailure : .registryInvalid,
                message: "The exact OCI archive could not be verified for provenance generation. No runtime mutation was attempted."
            )
        } catch is SecretStoreError {
            throw HostwrightDiagnostic(
                code: .secretUnavailable,
                message: "The provenance signing key could not be resolved at the authorized secret boundary. No secret reference or value was recorded."
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
                message: "The image provenance operation failed before changing runtime state."
            )
        }
    }

    private func generate(
        archivePath: String,
        recordPath: String,
        manifestPath: String,
        requestedServiceName: String?,
        server: String,
        repository: String,
        signerID: String,
        signingKeyReference: String,
        signingDate: Date,
        resumingGroup: OperationGroupRecord?
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        guard let signer = context.policy.policy.signers.first(
            where: { $0.id == signerID }
        ),
        signer.isActive(at: signingDate),
        let expectedKeySHA =
            context.policy.material.publicKeySHA256[signerID] else {
            throw invalid(
                "The selected provenance signer is not active in the exact manifest policy."
            )
        }
        let endpoint = try RegistryEndpoint(server)
        let repository = try OCIRepositoryName(repository)
        let subject = try OCIContentDigest(
            context.descriptorDigest
        )
        let reference = try HostwrightSecretReference.parse(
            signingKeyReference
        )
        let referenceSHA256 = sha256(
            Data(reference.rawValue.utf8)
        )
        let store = try migratedStore()
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
                    "recordPath": recordPath,
                    "recordPathSHA256":
                        sha256(Data(recordPath.utf8)),
                    "manifestPath": manifestPath,
                    "requestedServiceName":
                        requestedServiceName ?? NSNull(),
                    "endpoint": endpoint.canonicalURLString,
                    "repository": repository.value,
                    "signerID": signerID,
                    "secretReferenceSHA256": referenceSHA256,
                    "signingDate": timestamp(signingDate)
                ]
            )
        }

        var graphPersisted = false
        do {
            try checkCancellation()
            let inventory = try OCIImageArchiveSBOMGenerator()
                .inspect(
                    archivePath: archivePath,
                    expectedSubjectDigest: subject,
                    cancellation: cancellation
                )
            guard inventory.subjectDescriptor.digest == subject else {
                throw ImageProvenanceError
                    .subjectDigestMismatch
            }
            try checkCancellation()
            let recordData = Data(
                try environment.readTextFile(recordPath).utf8
            )
            let record = try ImageBuildProvenanceRecord.parse(
                recordData,
                expectedSubjectDigest: subject
            )
            let statementPayload = try record.statementPayload(
                signerID: signerID
            )
            try checkCancellation()
            let resolution = try environment.secretResolver()
                .resolve(
                    reference: reference,
                    for: try secretWorkload(context),
                    environmentKey:
                        "HOSTWRIGHT_PROVENANCE_SIGNING_KEY",
                    at: signingDate
                )
            try checkCancellation()
            let signed = try ImageProvenanceDSSEEnvelope.sign(
                statementPayload: statementPayload,
                expectedSubjectDigest: subject,
                signerID: signerID,
                privateKeyText: resolution.stringValue()
            )
            guard signed.publicKeySHA256 == expectedKeySHA else {
                throw ImageProvenanceError.policyRejected
            }
            _ = try ImageProvenanceVerifier.verify(
                envelopePayload: signed.envelopePayload,
                expectedSubjectDigest: subject,
                policy: context.policy.policy,
                material: context.policy.material,
                at: signingDate
            )
            let artifact = try ImageProvenanceArtifact.make(
                envelopePayload: signed.envelopePayload,
                subjectDescriptor: inventory.subjectDescriptor,
                endpoint: endpoint,
                repository: repository
            )
            try checkCancellation()
            let discovery = try store.ociReferrers.saveGraph(
                artifact.graph,
                observedAt: timestamp(signingDate)
            )
            graphPersisted = true
            try checkCancellation()
            guard let observedDiscovery =
                    try store.ociReferrers.loadDiscovery(
                        id: discovery.id
                    ),
                  let observedGraph =
                    try store.ociReferrers.loadGraph(
                        discoveryID: discovery.id
                    ),
                  observedDiscovery.complete,
                  observedDiscovery.graphSHA256 ==
                    discovery.graphSHA256,
                  observedDiscovery.subjectDigest ==
                    context.descriptorDigest else {
                throw invalid(
                    "The generated provenance graph failed exact post-operation observation."
                )
            }
            let observedEvidence =
                try ImageProvenanceEvidenceExtractor.extract(
                    from: observedGraph,
                    expectedSubjectDigest: subject
                )
            guard observedEvidence.count == 1,
                  observedEvidence[0].referrerDigest ==
                    artifact.rootDescriptor.digest else {
                throw invalid(
                    "The generated provenance graph did not contain one exact observed artifact."
                )
            }
            _ = try ImageProvenanceVerifier.verify(
                envelopePayload:
                    observedEvidence[0].envelopePayload,
                expectedSubjectDigest: subject,
                policy: context.policy.policy,
                material: context.policy.material,
                at: signingDate
            )
            try finish(
                store: store,
                group: group,
                checkpoint: "generated-graph-observed",
                verification: [
                    "discoveryID": discovery.id,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "referrerDigest":
                        artifact.rootDescriptor.digest
                            .canonicalValue,
                    "statementDigest":
                        signed.envelope.statement.statementDigest
                            .canonicalValue,
                    "envelopeDigest":
                        signed.envelope.envelopeDigest
                            .canonicalValue,
                    "signerID": signerID,
                    "signerPublicKeySHA256":
                        signed.publicKeySHA256
                ]
            )
            return render(
                operation: "generate",
                status: "generated",
                context: context,
                details: [
                    "discoveryID": discovery.id,
                    "evidenceGraphSHA256":
                        discovery.graphSHA256,
                    "referrerDigest":
                        artifact.rootDescriptor.digest
                            .canonicalValue,
                    "statementDigest":
                        signed.envelope.statement.statementDigest
                            .canonicalValue,
                    "envelopeDigest":
                        signed.envelope.envelopeDigest
                            .canonicalValue,
                    "signerID": signerID,
                    "operationGroupID": group.id,
                    "confirmationPlanSHA256": group.planHash,
                    "next":
                        "Publish the exact generated discovery with registry referrers publish, then fetch and verify the registry graph."
                ]
            )
        } catch {
            if graphPersisted ||
                (error as? ImageProvenanceError) == .cancelled ||
                cancellation.isCancelled {
                try? interrupt(
                    store: store,
                    group: group,
                    checkpoint: graphPersisted
                        ? "generated-graph-finalization-interrupted"
                        : "cancelled-at-bounded-checkpoint"
                )
            } else {
                try? fail(store: store, group: group)
            }
            throw error
        }
    }

    private func verify(
        discoveryID: String,
        referrerDigest: String,
        manifestPath: String,
        requestedServiceName: String?,
        verificationDate: Date,
        resumingGroup: OperationGroupRecord?
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        let store = try migratedStore()
        try ensureProjectIndexed(store: store, context: context)
        let exact = try exactEvidence(
            store: store,
            discoveryID: discoveryID,
            referrerDigest: referrerDigest,
            context: context
        )
        let group: OperationGroupRecord
        if let resumingGroup {
            try validate(
                resumingGroup: resumingGroup,
                operation: "verify",
                context: context
            )
            group = resumingGroup
        } else {
            group = try acquireGroup(
                store: store,
                operation: "verify",
                context: context,
                details: [
                    "discoveryID": discoveryID,
                    "evidenceGraphSHA256":
                        exact.discovery.graphSHA256,
                    "referrerDigest": referrerDigest,
                    "manifestPath": manifestPath,
                    "requestedServiceName":
                        requestedServiceName ?? NSNull(),
                    "verificationDate":
                        timestamp(verificationDate)
                ]
            )
        }

        var recordPersisted = false
        do {
            try checkCancellation()
            let verification = try ImageProvenanceVerifier.verify(
                envelopePayload: exact.evidence.envelopePayload,
                expectedSubjectDigest: try OCIContentDigest(
                    context.descriptorDigest
                ),
                policy: context.policy.policy,
                material: context.policy.material,
                at: verificationDate
            )
            try checkCancellation()
            let record = try store.imageProvenance.record(
                ImageProvenanceRecord(
                    projectID: context.projectID,
                    serviceName: context.serviceName,
                    referrerDigest: referrerDigest,
                    evidenceDiscoveryID: discoveryID,
                    evidenceGraphSHA256:
                        exact.discovery.graphSHA256,
                    verification: verification,
                    operationGroupID: group.id,
                    createdAt: timestamp(verificationDate)
                )
            )
            recordPersisted = true
            try checkCancellation()
            guard let observed = try store.imageProvenance
                    .loadRecord(id: record.id),
                  observed == record,
                  try recordIsCurrent(
                    observed,
                    store: store,
                    context: context,
                    at: verificationDate
                  ) else {
                throw invalid(
                    "The persisted provenance evidence failed exact post-operation observation."
                )
            }
            try finish(
                store: store,
                group: group,
                checkpoint: "verification-observed",
                verification: [
                    "recordID": record.id,
                    "discoveryID": discoveryID,
                    "evidenceGraphSHA256":
                        record.evidenceGraphSHA256,
                    "referrerDigest":
                        record.referrerDigest,
                    "statementDigest":
                        record.statementDigest,
                    "envelopeDigest":
                        record.envelopeDigest,
                    "policySHA256":
                        record.policySHA256
                ]
            )
            return render(
                operation: "verify",
                status: "verified",
                context: context,
                details: [
                    "record": recordObject(record),
                    "operationGroupID": group.id,
                    "confirmationPlanSHA256": group.planHash
                ]
            )
        } catch {
            if recordPersisted ||
                (error as? ImageProvenanceError) == .cancelled ||
                cancellation.isCancelled {
                try? interrupt(
                    store: store,
                    group: group,
                    checkpoint: recordPersisted
                        ? "evidence-finalization-interrupted"
                        : "cancelled-at-bounded-checkpoint"
                )
            } else {
                try? fail(store: store, group: group)
            }
            throw error
        }
    }

    private func status(
        manifestPath: String,
        requestedServiceName: String?
    ) throws -> CLIRunResult {
        let context = try policyContext(
            manifestPath: manifestPath,
            requestedServiceName: requestedServiceName
        )
        let store = try migratedStore()
        let records = try store.imageProvenance.loadRecords(
            projectID: context.projectID,
            serviceName: context.serviceName,
            descriptorDigest: context.descriptorDigest,
            policySHA256: context.policy.material.policySHA256
        )
        let now = environment.registryDate()
        var current: [ImageProvenanceRecord] = []
        for record in records {
            guard try recordIsCurrent(
                record,
                store: store,
                context: context,
                at: now
            ) else {
                throw invalid(
                    "Persisted provenance evidence no longer matches its exact graph, signer material, or current policy."
                )
            }
            current.append(record)
        }
        let satisfied = !current.isEmpty
        let status: String
        if satisfied {
            status = "satisfied"
        } else if context.policy.policy.requirement == .optional {
            status = "optional-not-present"
        } else {
            status = "blocked"
        }
        return render(
            operation: "status",
            status: status,
            context: context,
            details: [
                "recordCount": current.count,
                "records": current.map(recordObject)
            ]
        )
    }

    private func resume(
        operationGroupID: String,
        confirmationPlanSHA256: String,
        signingKeyReference: String?
    ) throws -> CLIRunResult {
        let store = try migratedStore()
        guard let source = try store.operationGroups.load(
            id: operationGroupID
        ),
        source.groupKind == Self.groupKind,
        source.planHash == confirmationPlanSHA256 else {
            throw invalid(
                "Image provenance recovery requires the exact operation group and confirmation plan."
            )
        }
        let intent = try strictIntent(source)
        let operation = try intentString(intent, "operation")
        switch operation {
        case "generate":
            try requireIntentKeys(
                intent,
                [
                    "apiVersion", "operation", "projectID",
                    "serviceName", "descriptorDigest",
                    "policySHA256", "archivePath",
                    "archivePathSHA256", "recordPath",
                    "recordPathSHA256", "manifestPath",
                    "requestedServiceName", "endpoint",
                    "repository", "signerID",
                    "secretReferenceSHA256",
                    "signingDate"
                ]
            )
            guard let signingKeyReference,
                  let reference = try?
                    HostwrightSecretReference.parse(
                        signingKeyReference
                    ),
                  sha256(Data(reference.rawValue.utf8)) ==
                    (try intentString(
                        intent,
                        "secretReferenceSHA256"
                    )) else {
                throw invalid(
                    "Provenance generation recovery requires the same typed signing-key reference; the reference is never persisted."
                )
            }
            let archivePath = try intentString(
                intent, "archivePath"
            )
            let recordPath = try intentString(
                intent, "recordPath"
            )
            guard sha256(Data(archivePath.utf8)) ==
                    (try intentString(
                        intent, "archivePathSHA256"
                    )),
                  sha256(Data(recordPath.utf8)) ==
                    (try intentString(
                        intent, "recordPathSHA256"
                    )) else {
                throw invalidRecoveryIntent()
            }
            let resumed = try resumeGroup(
                source,
                store: store
            )
            return try generate(
                archivePath: archivePath,
                recordPath: recordPath,
                manifestPath: try intentString(
                    intent, "manifestPath"
                ),
                requestedServiceName:
                    try optionalIntentString(
                        intent, "requestedServiceName"
                    ),
                server: try intentString(intent, "endpoint"),
                repository: try intentString(
                    intent, "repository"
                ),
                signerID: try intentString(
                    intent, "signerID"
                ),
                signingKeyReference: reference.rawValue,
                signingDate: try parseTimestamp(
                    intentString(intent, "signingDate")
                ),
                resumingGroup: resumed
            )
        case "verify":
            guard signingKeyReference == nil else {
                throw invalidRecoveryIntent()
            }
            try requireIntentKeys(
                intent,
                [
                    "apiVersion", "operation", "projectID",
                    "serviceName", "descriptorDigest",
                    "policySHA256", "discoveryID",
                    "evidenceGraphSHA256",
                    "referrerDigest", "manifestPath",
                    "requestedServiceName",
                    "verificationDate"
                ]
            )
            let resumed = try resumeGroup(
                source,
                store: store
            )
            return try verify(
                discoveryID: try intentString(
                    intent, "discoveryID"
                ),
                referrerDigest: try intentString(
                    intent, "referrerDigest"
                ),
                manifestPath: try intentString(
                    intent, "manifestPath"
                ),
                requestedServiceName:
                    try optionalIntentString(
                        intent, "requestedServiceName"
                    ),
                verificationDate: try parseTimestamp(
                    intentString(intent, "verificationDate")
                ),
                resumingGroup: resumed
            )
        default:
            throw invalidRecoveryIntent()
        }
    }

    private func policyContext(
        manifestPath: String,
        requestedServiceName: String?
    ) throws -> ProvenanceContext {
        let text = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let manifest = try hostwrightValidatedManifest(
            text: text,
            teamProfilePath: nil,
            environment: environment
        ).manifest
        let policy = try ImageProvenancePolicyMapping.map(
            manifest
        )
        let serviceName =
            try ImageProvenancePolicyMapping.selectService(
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
                message: "Image provenance policy requires an exact digest-pinned service image."
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
                message: "Image provenance policy requires a canonical sha256 image digest."
            )
        }
        return ProvenanceContext(
            projectID: "project-\(project)",
            serviceName: serviceName,
            descriptorDigest: digest,
            policy: policy,
            manifest: manifest,
            manifestPath: manifestPath,
            manifestSHA256: sha256(Data(text.utf8))
        )
    }

    private func ensureProjectIndexed(
        store: SQLiteStateStore,
        context: ProvenanceContext
    ) throws {
        if let existing = try? store.desiredStates.loadProject(
            id: context.projectID
        ) {
            guard existing.name == context.manifest.project else {
                throw invalid(
                    "The provenance project identity conflicts with existing state."
                )
            }
            return
        }
        try store.desiredStates.saveManifestSnapshot(
            projectID: context.projectID,
            manifestPath: context.manifestPath,
            manifestHash: context.manifestSHA256,
            desiredGeneration: 1,
            manifest: context.manifest,
            timestamp: timestamp(environment.registryDate())
        )
    }

    private func exactEvidence(
        store: SQLiteStateStore,
        discoveryID: String,
        referrerDigest: String,
        context: ProvenanceContext
    ) throws -> (
        discovery: OCIReferrerDiscoveryRecord,
        evidence: ImageProvenanceEvidence
    ) {
        guard let discovery = try store.ociReferrers
                .loadDiscovery(id: discoveryID),
              let graph = try store.ociReferrers.loadGraph(
                  discoveryID: discoveryID
              ),
              discovery.complete,
              discovery.subjectDigest ==
                context.descriptorDigest else {
            throw invalid(
                "The exact complete verified OCI provenance graph was not found."
            )
        }
        let evidence = try ImageProvenanceEvidenceExtractor
            .extract(
                from: graph,
                expectedSubjectDigest: try OCIContentDigest(
                    context.descriptorDigest
                )
            ).filter {
                $0.referrerDigest.canonicalValue ==
                    referrerDigest
            }
        guard evidence.count == 1,
              let exact = evidence.first else {
            throw invalid(
                "The requested provenance referrer was not uniquely present in the exact verified graph."
            )
        }
        return (discovery, exact)
    }

    private func recordIsCurrent(
        _ record: ImageProvenanceRecord,
        store: SQLiteStateStore,
        context: ProvenanceContext,
        at date: Date
    ) throws -> Bool {
        let exact = try exactEvidence(
            store: store,
            discoveryID: record.evidenceDiscoveryID,
            referrerDigest: record.referrerDigest,
            context: context
        )
        guard exact.discovery.graphSHA256 ==
                record.evidenceGraphSHA256 else {
            return false
        }
        let verification = try ImageProvenanceVerifier.verify(
            envelopePayload: exact.evidence.envelopePayload,
            expectedSubjectDigest: try OCIContentDigest(
                context.descriptorDigest
            ),
            policy: context.policy.policy,
            material: context.policy.material,
            at: date
        )
        let statement = verification.statement
        return record.projectID == context.projectID &&
            record.serviceName == context.serviceName &&
            record.descriptorDigest ==
                statement.subjectDigest.canonicalValue &&
            record.policySHA256 ==
                verification.policySHA256 &&
            record.statementDigest ==
                statement.statementDigest.canonicalValue &&
            record.envelopeDigest ==
                verification.envelopeDigest.canonicalValue &&
            record.sourceURI == statement.source.uri &&
            record.sourceDigest ==
                statement.source.digest.canonicalValue &&
            record.builderID == statement.builderID &&
            record.builderVersion == statement.builderVersion &&
            record.buildType == statement.buildType &&
            record.invocationID == statement.invocationID &&
            record.normalizedMaterialsSHA256 ==
                statement.normalizedMaterialsSHA256 &&
            record.commandSHA256 == statement.commandSHA256 &&
            record.environmentPolicySHA256 ==
                statement.environmentPolicySHA256 &&
            record.startedAt == statement.startedAt &&
            record.finishedAt == statement.finishedAt &&
            record.reproducibilityStatus ==
                statement.reproducibility.status &&
            record.comparisonDigest ==
                statement.reproducibility.comparisonDigest?
                    .canonicalValue &&
            record.signerID == verification.signerID &&
            record.signerPublicKeySHA256 ==
                verification.signerPublicKeySHA256 &&
            record.signatureSHA256 ==
                verification.signatureSHA256 &&
            record.verifierVersion ==
                ImageProvenanceVerification.verifierVersion
    }

    private func secretWorkload(
        _ context: ProvenanceContext
    ) throws -> HostwrightSecretWorkloadScope {
        guard let projectID = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "project",
                identifier: context.projectID
            )
        ),
        let resourceID = UUID(
            uuidString: HostwrightResourceUUID.legacy(
                kind: "image-provenance-signer",
                identifier: [
                    context.projectID,
                    context.serviceName,
                    context.descriptorDigest
                ].joined(separator: "\u{1f}")
            )
        ) else {
            throw SecretStoreError.invalidReference(
                "Provenance signing requires exact resource identities."
            )
        }
        return try HostwrightSecretWorkloadScope(
            projectID: projectID,
            resourceID: resourceID,
            generation: 1,
            serviceName: context.serviceName
        )
    }

    private func migratedStore() throws -> SQLiteStateStore {
        let store = SQLiteStateStore(
            configuration:
                try hostwrightStateStoreConfiguration(
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
        context: ProvenanceContext,
        details: [String: Any]
    ) throws -> OperationGroupRecord {
        var intent = details
        intent["apiVersion"] = Self.apiVersion
        intent["operation"] = operation
        intent["projectID"] = context.projectID
        intent["serviceName"] = context.serviceName
        intent["descriptorDigest"] =
            context.descriptorDigest
        intent["policySHA256"] =
            context.policy.material.policySHA256
        let data = try JSONSerialization.data(
            withJSONObject: intent,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard data.count <= 64 * 1_024 else {
            throw invalid(
                "Image provenance durable intent exceeded its bound."
            )
        }
        let plan = sha256(data)
        let now = timestamp(environment.registryDate())
        let id = UUID().uuidString.lowercased()
        let group = OperationGroupRecord(
            id: id,
            operationID: id,
            groupKind: Self.groupKind,
            projectID: context.projectID,
            serviceName: context.serviceName,
            plannedActionType: operation,
            status: .active,
            groupIdempotencyKey: plan,
            planHash: plan,
            checkpoint: "intent-persisted",
            lockOwner: "hostwright-registry-provenance",
            lockExpiresAt: hostwrightTimestampAdding(
                seconds: 300,
                to: now
            ),
            rollbackAvailable: false,
            manualRecoveryHintRedacted:
                "Resume the exact provenance operation. Signing-key references and values are never persisted.",
            createdAt: now,
            updatedAt: now,
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-provenance/v1"}"#,
            fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted: String(
                decoding: data,
                as: UTF8.self
            ),
            compensationJSONRedacted: "[]",
            verificationJSONRedacted: "{}"
        )
        let result = try store.operationGroups.acquire(
            group,
            currentTimestamp: now
        )
        guard let acquired = result.acquired else {
            throw HostwrightDiagnostic(
                code: .partialFailure,
                message: "An exact image provenance operation is already active."
            )
        }
        return acquired
    }

    private func validate(
        resumingGroup: OperationGroupRecord,
        operation: String,
        context: ProvenanceContext
    ) throws {
        guard resumingGroup.groupKind == Self.groupKind,
              resumingGroup.plannedActionType == operation,
              resumingGroup.projectID == context.projectID,
              resumingGroup.serviceName ==
                context.serviceName,
              let data = resumingGroup.intentJSONRedacted
                .data(using: .utf8),
              let intent = try JSONSerialization.jsonObject(
                  with: data
              ) as? [String: Any],
              intent["descriptorDigest"] as? String ==
                context.descriptorDigest,
              intent["policySHA256"] as? String ==
                context.policy.material.policySHA256 else {
            throw invalid(
                "Image provenance recovery no longer matches the exact manifest policy and image digest."
            )
        }
    }

    private func strictIntent(
        _ source: OperationGroupRecord
    ) throws -> [String: Any] {
        guard let data = source.intentJSONRedacted.data(
            using: .utf8
        ),
        let intent = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
        intent["apiVersion"] as? String == Self.apiVersion,
        intent["operation"] as? String ==
            source.plannedActionType,
        intent["projectID"] as? String == source.projectID,
        intent["serviceName"] as? String ==
            source.serviceName,
        sha256(
            try JSONSerialization.data(
                withJSONObject: intent,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        ) == source.planHash else {
            throw invalidRecoveryIntent()
        }
        return intent
    }

    private func resumeGroup(
        _ source: OperationGroupRecord,
        store: SQLiteStateStore
    ) throws -> OperationGroupRecord {
        let now = timestamp(environment.registryDate())
        switch source.status {
        case .interrupted:
            return try store.operationGroups.resumeInterrupted(
                groupID: source.id,
                expectedFencingToken: source.fencingToken,
                lockOwner:
                    "hostwright-registry-provenance-recovery",
                lockExpiresAt: hostwrightTimestampAdding(
                    seconds: 300,
                    to: now
                ),
                updatedAt: now
            )
        case .active:
            let result = try store.operationGroups
                .reclaimExpiredActive(
                    groupID: source.id,
                    expectedPlanHash: source.planHash,
                    expectedFencingToken:
                        source.fencingToken,
                    lockOwner:
                        "hostwright-registry-provenance-recovery",
                    lockExpiresAt:
                        hostwrightTimestampAdding(
                            seconds: 300,
                            to: now
                        ),
                    currentTimestamp: now
                )
            switch result {
            case .reclaimed(let group):
                return group
            case .activeUnexpired:
                throw HostwrightDiagnostic(
                    code: .partialFailure,
                    message: "The exact image provenance operation lease is still active; recovery refused to race it."
                )
            }
        case .succeeded, .failed:
            throw invalid(
                "Only interrupted or expired active image provenance operations can be resumed."
            )
        }
    }

    private func finish(
        store: SQLiteStateStore,
        group: OperationGroupRecord,
        checkpoint: String,
        verification: [String: Any]
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: verification,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let now = timestamp(environment.registryDate())
        try store.operationGroups.recordCheckpoint(
            groupID: group.id,
            expectedFencingToken: group.fencingToken,
            checkpoint: checkpoint,
            verificationJSONRedacted: String(
                decoding: data,
                as: UTF8.self
            ),
            updatedAt: now
        )
        try store.operationGroups.finish(
            groupID: group.id,
            status: .succeeded,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted: "",
            updatedAt: now,
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-provenance/v1"}"#
        )
    }

    private func fail(
        store: SQLiteStateStore,
        group: OperationGroupRecord
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .failed,
            checkpoint: "failed-no-external-effect",
            manualRecoveryHintRedacted:
                "Correct the exact provenance input and start a new operation.",
            updatedAt: timestamp(environment.registryDate()),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-provenance/v1"}"#
        )
    }

    private func interrupt(
        store: SQLiteStateStore,
        group: OperationGroupRecord,
        checkpoint: String
    ) throws {
        try store.operationGroups.finish(
            groupID: group.id,
            status: .interrupted,
            checkpoint: checkpoint,
            manualRecoveryHintRedacted:
                "Resume with the exact operation group and confirmation plan. Generation also requires resupplying the same typed signing-key reference.",
            updatedAt: timestamp(environment.registryDate()),
            metadataJSONRedacted:
                #"{"contract":"hostwright.dev/image-provenance/v1"}"#
        )
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

    private func recordObject(
        _ record: ImageProvenanceRecord
    ) -> [String: Any] {
        [
            "id": record.id,
            "descriptorDigest": record.descriptorDigest,
            "policySHA256": record.policySHA256,
            "statementDigest": record.statementDigest,
            "envelopeDigest": record.envelopeDigest,
            "referrerDigest": record.referrerDigest,
            "discoveryID": record.evidenceDiscoveryID,
            "evidenceGraphSHA256":
                record.evidenceGraphSHA256,
            "sourceURI": record.sourceURI,
            "sourceDigest": record.sourceDigest,
            "builderID": record.builderID,
            "builderVersion": record.builderVersion,
            "buildType": record.buildType,
            "invocationID": record.invocationID,
            "normalizedMaterialsSHA256":
                record.normalizedMaterialsSHA256,
            "commandSHA256": record.commandSHA256,
            "environmentPolicySHA256":
                record.environmentPolicySHA256,
            "startedAt": record.startedAt,
            "finishedAt": record.finishedAt,
            "reproducibilityStatus":
                record.reproducibilityStatus.rawValue,
            "comparisonDigest":
                record.comparisonDigest ?? NSNull(),
            "signerID": record.signerID,
            "signerPublicKeySHA256":
                record.signerPublicKeySHA256,
            "signatureSHA256": record.signatureSHA256,
            "verifierVersion": record.verifierVersion,
            "verifiedAt": record.verifiedAt
        ]
    }

    private func render(
        operation: String,
        status: String,
        context: ProvenanceContext,
        details: [String: Any]
    ) -> CLIRunResult {
        let object: [String: Any] = [
            "apiVersion": Self.apiVersion,
            "operation": operation,
            "status": status,
            "projectID": context.projectID,
            "serviceName": context.serviceName,
            "descriptorDigest": context.descriptorDigest,
            "policySHA256":
                context.policy.material.policySHA256,
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
                "Image provenance \(operation): \(status)\n" +
                "Service: \(context.serviceName)\n" +
                "Digest: \(context.descriptorDigest)\n"
        )
    }

    private func checkCancellation() throws {
        guard !cancellation.isCancelled else {
            throw ImageProvenanceError.cancelled
        }
    }

    private func parseTimestamp(_ value: String) throws
        -> Date
    {
        let exact = ISO8601DateFormatter()
        exact.formatOptions = [.withInternetDateTime]
        if let date = exact.date(from: value) {
            return date
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        guard let date = fractional.date(from: value) else {
            throw invalidRecoveryIntent()
        }
        return date
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds
        ]
        return formatter.string(from: date)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func invalid(
        _ message: String
    ) -> HostwrightDiagnostic {
        HostwrightDiagnostic(
            code: .registryInvalid,
            message: message
        )
    }

    private func invalidRecoveryIntent()
        -> HostwrightDiagnostic
    {
        invalid(
            "The stored image provenance recovery intent is invalid."
        )
    }
}

private struct ProvenanceContext {
    let projectID: String
    let serviceName: String
    let descriptorDigest: String
    let policy: ImageProvenancePolicyContext
    let manifest: HostwrightManifest
    let manifestPath: String
    let manifestSHA256: String
}
