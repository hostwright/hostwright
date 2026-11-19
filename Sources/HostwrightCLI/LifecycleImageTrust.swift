import CryptoKit
import Foundation
import HostwrightCore
import HostwrightManifest
import HostwrightNetworking
import HostwrightObservability
import HostwrightPolicy
import HostwrightReconciler
import HostwrightRegistry
import HostwrightRuntime
import HostwrightSecrets
import HostwrightState
import HostwrightStorage

func lifecyclePreflightImageTrust(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    guard manifest.imageTrust != nil else { return }
    let mapping = try ImageTrustPolicyMapping.map(manifest)
    let now = Date()
    let timestamp = hostwrightTimestamp()
    let rootSHA256 =
        mapping.material.trustedRootSHA256 ?? lifecycleSHA256(Data())
    let activeAuthorityIDs = Set(
        mapping.policy.authorities.filter { authority in
            if let notBefore = authority.notBefore, now < notBefore {
                return false
            }
            if let notAfter = authority.notAfter, now > notAfter {
                return false
            }
            if let revokedAt = authority.revokedAt, now >= revokedAt {
                return false
            }
            return true
        }.map(\.id)
    )
    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)

    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Image trust requires an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let verifications = try store.imageTrust.loadVerifications(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest
        )
        var verified = false
        for record in verifications.reversed() {
            let matched = Set(record.matchedAuthorityIDs)
            guard record.policySHA256 == mapping.material.policySHA256,
                  record.trustedRootSHA256 == rootSHA256,
                  record.outcome ==
                    ImageTrustVerificationOutcome.passed.rawValue,
                  record.threshold == mapping.policy.threshold,
                  matched.count >= record.threshold,
                  matched.isSubset(of: activeAuthorityIDs),
                  let discovery = try store.ociReferrers.loadDiscovery(
                      id: record.evidenceDiscoveryID
                  ),
                  discovery.complete,
                  discovery.graphSHA256 == record.evidenceGraphSHA256,
                  discovery.subjectDigest == lock.descriptorDigest,
                  let graph = try store.ociReferrers.loadGraph(
                      discoveryID: record.evidenceDiscoveryID
                  ),
                  graph.discovery.subjectDigest.canonicalValue ==
                    lock.descriptorDigest,
                  let subject = try store.imageTrust.loadSubjectManifest(
                      endpoint: discovery.registryEndpoint,
                      repository: discovery.repository,
                      descriptorDigest: lock.descriptorDigest
                  ),
                  subject.payloadSHA256 ==
                    String(lock.descriptorDigest.dropFirst(7)),
                  lifecycleSHA256(subject.payload) ==
                    subject.payloadSHA256,
                  (try? ImageTrustEvidenceExtractor.bundles(
                      from: graph
                  )) != nil else {
                continue
            }
            verified = true
            try lifecycleRecordTrustAuthorization(
                store: store,
                timestamp: timestamp,
                planSHA256: planSHA256,
                projectID: projectID,
                providerID: providerID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                policySHA256: mapping.material.policySHA256,
                authorization: "verified",
                verification: record,
                exception: nil
            )
            break
        }
        if verified { continue }

        if let exception = try store.imageTrust.activeException(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: mapping.material.policySHA256,
            currentTimestamp: timestamp
        ) {
            let payload = try JSONSerialization.data(
                withJSONObject: [
                    "exceptionID": exception.id,
                    "descriptorDigest": lock.descriptorDigest,
                    "policySHA256": mapping.material.policySHA256
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            try store.events.append([
                EventRecord(
                    id: UUID().uuidString.lowercased(),
                    timestamp: timestamp,
                    severity: .warning,
                    type: "image.trust.exception.used",
                    source: "hostwright.lifecycle",
                    projectID: projectID,
                    serviceName: serviceName,
                    runtimeAdapter: providerID.rawValue,
                    message: "An exact active image trust exception authorized lifecycle preflight.",
                    payloadJSONRedacted:
                        String(decoding: payload, as: UTF8.self)
                ),
                try lifecycleTrustAuthorizationEvent(
                    timestamp: timestamp,
                    planSHA256: planSHA256,
                    projectID: projectID,
                    providerID: providerID,
                    serviceName: serviceName,
                    descriptorDigest: lock.descriptorDigest,
                    policySHA256:
                        mapping.material.policySHA256,
                    authorization: "exception",
                    verification: nil,
                    exception: exception
                )
            ])
            continue
        }
        throw RuntimeAdapterError.mutationUnavailableByPolicy(
            "No current image trust verification or exact active exception matches service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
        )
    }
}

func lifecyclePreflightImageSBOM(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    guard let source = manifest.imageSBOM,
          source.requirement == .required else {
        return
    }
    let policy = try ImageSBOMPolicyMapping.map(manifest)
    let requiredFormats = Set(policy.formats.map(\.rawValue))
    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)
    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required image SBOM policy needs an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let records = try store.imageSBOM.loadRecords(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: policy.policySHA256
        )
        let verified = try lifecycleVerifiedSBOMFormats(
            records: records,
            descriptorDigest: lock.descriptorDigest,
            store: store
        )
        guard requiredFormats.isSubset(of: verified) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required exact image SBOM evidence is missing or invalid for service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
            )
        }
        let applicable = records.filter {
            verified.contains($0.format.rawValue)
        }
        let object: [String: Any] = [
            "planSHA256": planSHA256,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": lock.descriptorDigest,
            "policySHA256": policy.policySHA256,
            "formats": requiredFormats.sorted(),
            "records": applicable.map {
                [
                    "format": $0.format.rawValue,
                    "documentDigest": $0.documentDigest,
                    "discoveryID": $0.evidenceDiscoveryID,
                    "graphSHA256": $0.evidenceGraphSHA256,
                    "referrerDigest": $0.sbomReferrerDigest
                ]
            }
        ]
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity: .info,
                type: "image.sbom.lifecycle.authorized",
                source: "hostwright.lifecycle",
                projectID: projectID,
                serviceName: serviceName,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Exact image SBOM evidence authorized lifecycle execution.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ])
    }
}

func lifecyclePreflightImageProvenance(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    desiredState: DesiredRuntimeState,
    store: SQLiteStateStore,
    manifest: HostwrightManifest
) throws {
    let mapping = try manifest.imageProvenance.map { _ in
        try ImageProvenancePolicyMapping.map(manifest)
    }
    guard let mapping,
          mapping.policy.requirement == .required else {
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "planSHA256": planSHA256,
                "projectID": projectID,
                "required": false,
                "policySHA256": mapping.map {
                    $0.material.policySHA256 as Any
                } ?? NSNull()
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try store.events.append([
            EventRecord(
                id: UUID().uuidString.lowercased(),
                timestamp: hostwrightTimestamp(),
                severity: .info,
                type:
                    "image.provenance.lifecycle.not-required",
                source: "hostwright.lifecycle",
                projectID: nil,
                serviceName: nil,
                runtimeAdapter: providerID.rawValue,
                message:
                    "Image provenance policy was not required for this exact lifecycle plan.",
                payloadJSONRedacted:
                    String(decoding: payload, as: UTF8.self)
            )
        ])
        return
    }

    let services = Dictionary(
        grouping: desiredState.services,
        by: \.logicalServiceName
    ).compactMapValues(\.first)
    let now = Date()
    for serviceName in services.keys.sorted() {
        guard let service = services[serviceName],
              let lock = service.imageLock else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required image provenance policy needs an exact provider-bound digest lock for every desired service. No runtime mutation was attempted."
            )
        }
        let records = try store.imageProvenance.loadRecords(
            projectID: projectID,
            serviceName: serviceName,
            descriptorDigest: lock.descriptorDigest,
            policySHA256: mapping.material.policySHA256
        )
        guard let record = try lifecycleCurrentProvenanceRecord(
            records: records,
            descriptorDigest: lock.descriptorDigest,
            policy: mapping.policy,
            material: mapping.material,
            store: store,
            at: now
        ) else {
            throw RuntimeAdapterError.mutationUnavailableByPolicy(
                "Required exact image provenance is missing, expired, or invalid for service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
            )
        }
        try store.events.append([
            try lifecycleProvenanceAuthorizationEvent(
                planSHA256: planSHA256,
                projectID: projectID,
                providerID: providerID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                record: record
            )
        ])
    }
}

func lifecycleVerifiedSBOMFormats(
    records: [ImageSBOMRecord],
    descriptorDigest: String,
    store: SQLiteStateStore
) throws -> Set<String> {
    var verified = Set<String>()
    for record in records.reversed() {
        guard let discovery = try store.ociReferrers
            .loadDiscovery(id: record.evidenceDiscoveryID),
            discovery.complete,
            discovery.subjectDigest == descriptorDigest,
            discovery.graphSHA256 ==
                record.evidenceGraphSHA256,
            let graph = try store.ociReferrers.loadGraph(
                discoveryID: record.evidenceDiscoveryID
            ),
            let format = ImageSBOMFormat(
                rawValue: record.format.rawValue
            ),
            let evidence = try? ImageSBOMEvidenceExtractor.extract(
                from: graph,
                expectedSubjectDigest:
                    OCIContentDigest(descriptorDigest),
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
                $0.provenanceDescriptorDigest?.canonicalValue ==
                    record.provenanceDescriptorDigest &&
                $0.provenanceReferrerDigest?.canonicalValue ==
                    record.provenanceReferrerDigest
            }) else {
            continue
        }
        verified.insert(record.format.rawValue)
    }
    return verified
}

func lifecycleCurrentProvenanceRecord(
    records: [ImageProvenanceRecord],
    descriptorDigest: String,
    policy: ImageProvenancePolicy,
    material: ImageProvenancePolicyMaterial,
    store: SQLiteStateStore,
    at date: Date
) throws -> ImageProvenanceRecord? {
    let expectedDigest = try OCIContentDigest(descriptorDigest)
    for record in records.reversed() {
        guard record.descriptorDigest == descriptorDigest,
              record.policySHA256 == material.policySHA256,
              record.verifierVersion ==
                ImageProvenanceVerification.verifierVersion,
              let discovery =
                try store.ociReferrers.loadDiscovery(
                    id: record.evidenceDiscoveryID
                ),
              discovery.complete,
              discovery.subjectDigest == descriptorDigest,
              discovery.graphSHA256 ==
                record.evidenceGraphSHA256,
              let graph = try store.ociReferrers.loadGraph(
                  discoveryID: record.evidenceDiscoveryID
              ),
              graph.discovery.subjectDigest == expectedDigest,
              let evidence =
                try? ImageProvenanceEvidenceExtractor.extract(
                    from: graph,
                    expectedSubjectDigest: expectedDigest
                ).first(where: {
                    $0.referrerDigest.canonicalValue ==
                        record.referrerDigest &&
                        $0.envelopeDescriptor.digest
                            .canonicalValue ==
                        record.envelopeDigest
                }),
              let verification =
                try? ImageProvenanceVerifier.verify(
                    envelopePayload: evidence.envelopePayload,
                    expectedSubjectDigest: expectedDigest,
                    policy: policy,
                    material: material,
                    at: date
                ),
              lifecycleProvenanceRecord(
                  record,
                  exactlyMatches: verification,
                  referrerDigest:
                    evidence.referrerDigest.canonicalValue
              ) else {
            continue
        }
        return record
    }
    return nil
}

private func lifecycleProvenanceRecord(
    _ record: ImageProvenanceRecord,
    exactlyMatches verification: ImageProvenanceVerification,
    referrerDigest: String
) -> Bool {
    let statement = verification.statement
    return record.descriptorDigest ==
        statement.subjectDigest.canonicalValue &&
        record.policySHA256 == verification.policySHA256 &&
        record.statementDigest ==
        statement.statementDigest.canonicalValue &&
        record.envelopeDigest ==
        verification.envelopeDigest.canonicalValue &&
        record.referrerDigest == referrerDigest &&
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
        verification.signatureSHA256
}

func lifecycleProvenanceEvent(
    _ object: [String: Any],
    exactlyMatches record: ImageProvenanceRecord
) -> Bool {
    object["recordID"] as? String == record.id &&
        object["policySHA256"] as? String ==
        record.policySHA256 &&
        object["statementDigest"] as? String ==
        record.statementDigest &&
        object["envelopeDigest"] as? String ==
        record.envelopeDigest &&
        object["referrerDigest"] as? String ==
        record.referrerDigest &&
        object["discoveryID"] as? String ==
        record.evidenceDiscoveryID &&
        object["graphSHA256"] as? String ==
        record.evidenceGraphSHA256 &&
        object["signerID"] as? String ==
        record.signerID &&
        object["signerPublicKeySHA256"] as? String ==
        record.signerPublicKeySHA256 &&
        object["signatureSHA256"] as? String ==
        record.signatureSHA256
}

private func lifecycleProvenanceAuthorizationEvent(
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    record: ImageProvenanceRecord
) throws -> EventRecord {
    let payload = try JSONSerialization.data(
        withJSONObject: [
            "planSHA256": planSHA256,
            "projectID": projectID,
            "serviceName": serviceName,
            "descriptorDigest": descriptorDigest,
            "policySHA256": record.policySHA256,
            "recordID": record.id,
            "statementDigest": record.statementDigest,
            "envelopeDigest": record.envelopeDigest,
            "referrerDigest": record.referrerDigest,
            "discoveryID": record.evidenceDiscoveryID,
            "graphSHA256": record.evidenceGraphSHA256,
            "signerID": record.signerID,
            "signerPublicKeySHA256":
                record.signerPublicKeySHA256,
            "signatureSHA256": record.signatureSHA256
        ],
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return EventRecord(
        id: UUID().uuidString.lowercased(),
        timestamp: hostwrightTimestamp(),
        severity: .info,
        type: "image.provenance.lifecycle.authorized",
        source: "hostwright.lifecycle",
        projectID: projectID,
        serviceName: serviceName,
        runtimeAdapter: providerID.rawValue,
        message:
            "Exact signed image provenance authorized lifecycle execution.",
        payloadJSONRedacted:
            String(decoding: payload, as: UTF8.self)
    )
}

private func lifecycleRecordTrustAuthorization(
    store: SQLiteStateStore,
    timestamp: String,
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    policySHA256: String,
    authorization: String,
    verification: ImageTrustVerificationRecord?,
    exception: ImageTrustExceptionRecord?
) throws {
    try store.events.append([
        try lifecycleTrustAuthorizationEvent(
            timestamp: timestamp,
            planSHA256: planSHA256,
            projectID: projectID,
            providerID: providerID,
            serviceName: serviceName,
            descriptorDigest: descriptorDigest,
            policySHA256: policySHA256,
            authorization: authorization,
            verification: verification,
            exception: exception
        )
    ])
}

private func lifecycleTrustAuthorizationEvent(
    timestamp: String,
    planSHA256: String,
    projectID: String,
    providerID: RuntimeProviderID,
    serviceName: String,
    descriptorDigest: String,
    policySHA256: String,
    authorization: String,
    verification: ImageTrustVerificationRecord?,
    exception: ImageTrustExceptionRecord?
) throws -> EventRecord {
    var object: [String: Any] = [
        "decision": authorization,
        "planSHA256": planSHA256,
        "projectID": projectID,
        "serviceName": serviceName,
        "descriptorDigest": descriptorDigest,
        "policySHA256": policySHA256
    ]
    if let verification {
        object["verification"] = [
            "createdAt": verification.createdAt,
            "discoveryID": verification.evidenceDiscoveryID,
            "graphSHA256": verification.evidenceGraphSHA256,
            "trustedRootSHA256":
                verification.trustedRootSHA256
        ]
    }
    if let exception {
        object["exceptionID"] = exception.id
    }
    let payload = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    return EventRecord(
        id: UUID().uuidString.lowercased(),
        timestamp: timestamp,
        severity: authorization == "exception"
            ? .warning : .info,
        type: "image.trust.lifecycle.authorized",
        source: "hostwright.lifecycle",
        projectID: projectID,
        serviceName: serviceName,
        runtimeAdapter: providerID.rawValue,
        message:
            "Exact image trust evidence authorized lifecycle execution.",
        payloadJSONRedacted: String(decoding: payload, as: UTF8.self)
    )
}
