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

extension LifecyclePersistedRecoveryDriver {
    func preflightImageTrustRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let authorizationObjects = try store.events.loadAll()
            .filter {
                $0.type == "image.trust.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data = event.payloadJSONRedacted.data(
                    using: .utf8
                ),
                let object = try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                object["planSHA256"] as? String ==
                    plan.planSHA256 else {
                    return nil
                }
                return object
            }
        guard !authorizationObjects.isEmpty else {
            return
        }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoveryTrustSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let candidates = authorizationObjects.filter {
                $0["projectID"] as? String == plan.projectID &&
                    $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let policySHA256 =
                        object["policySHA256"] as? String,
                      policySHA256.range(
                          of: "^[a-f0-9]{64}$",
                          options: .regularExpression
                      ) != nil,
                      let authorization =
                        object["decision"] as? String else {
                    continue
                }
                if authorization == "verified",
                   let verification =
                    object["verification"] as? [String: Any],
                   let createdAt =
                    verification["createdAt"] as? String,
                   let discoveryID =
                    verification["discoveryID"] as? String,
                   let graphSHA256 =
                    verification["graphSHA256"] as? String,
                   let rootSHA256 =
                    verification["trustedRootSHA256"] as? String,
                   let record = try store.imageTrust
                    .loadVerifications(
                        projectID: plan.projectID,
                        serviceName: serviceName,
                        descriptorDigest: lock.descriptorDigest
                    )
                    .first(where: {
                        $0.policySHA256 == policySHA256 &&
                            $0.createdAt == createdAt &&
                            $0.evidenceDiscoveryID ==
                                discoveryID &&
                            $0.evidenceGraphSHA256 ==
                                graphSHA256 &&
                            $0.trustedRootSHA256 ==
                                rootSHA256 &&
                            $0.outcome ==
                                ImageTrustVerificationOutcome
                                    .passed.rawValue &&
                            $0.matchedAuthorityIDs.count >=
                                $0.threshold
                    }),
                   let discovery =
                    try store.ociReferrers.loadDiscovery(
                        id: record.evidenceDiscoveryID
                    ),
                   discovery.complete,
                   discovery.graphSHA256 ==
                    record.evidenceGraphSHA256,
                   discovery.subjectDigest ==
                    lock.descriptorDigest,
                   let graph = try store.ociReferrers.loadGraph(
                       discoveryID: record.evidenceDiscoveryID
                   ),
                   let subject =
                    try store.imageTrust.loadSubjectManifest(
                        endpoint: discovery.registryEndpoint,
                        repository: discovery.repository,
                        descriptorDigest: lock.descriptorDigest
                    ),
                   lifecycleSHA256(subject.payload) ==
                    subject.payloadSHA256,
                   subject.descriptorDigest ==
                    lock.descriptorDigest,
                   (try? ImageTrustEvidenceExtractor.bundles(
                       from: graph
                   )) != nil {
                    authorized = true
                    break
                }
                if authorization == "exception",
                   let exceptionID =
                    object["exceptionID"] as? String,
                   let exception =
                    try store.imageTrust.activeException(
                        projectID: plan.projectID,
                        serviceName: serviceName,
                        descriptorDigest: lock.descriptorDigest,
                        policySHA256: policySHA256,
                        currentTimestamp: hostwrightTimestamp()
                    ),
                   exception.id == exceptionID {
                    authorized = true
                    break
                }
            }
            guard authorized else {
                throw recoveryTrustSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    func preflightImageSBOMRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let authorizationObjects = try store.events.loadAll()
            .filter {
                $0.type == "image.sbom.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data = event.payloadJSONRedacted.data(
                    using: .utf8
                ),
                let object = try? JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                object["planSHA256"] as? String ==
                    plan.planSHA256 else {
                    return nil
                }
                return object
            }
        guard !authorizationObjects.isEmpty else {
            return
        }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoverySBOMSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let candidates = authorizationObjects.filter {
                $0["projectID"] as? String == plan.projectID &&
                    $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let policySHA256 =
                    object["policySHA256"] as? String,
                    policySHA256.range(
                        of: "^[a-f0-9]{64}$",
                        options: .regularExpression
                    ) != nil,
                    let formats = object["formats"] as? [String],
                    !formats.isEmpty else {
                    continue
                }
                let records = try store.imageSBOM.loadRecords(
                    projectID: plan.projectID,
                    serviceName: serviceName,
                    descriptorDigest: lock.descriptorDigest,
                    policySHA256: policySHA256
                )
                let required = Set(formats)
                let verified = try lifecycleVerifiedSBOMFormats(
                    records: records,
                    descriptorDigest: lock.descriptorDigest,
                    store: store
                )
                if required.isSubset(of: verified) {
                    authorized = true
                    break
                }
            }
            guard authorized else {
                throw recoverySBOMSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    func preflightImageProvenanceRecovery(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws {
        let allEvents = try store.events.loadAll()
        let notRequiredObjects = allEvents.compactMap {
            event -> [String: Any]? in
            guard event.type ==
                    "image.provenance.lifecycle.not-required",
                  let data = event.payloadJSONRedacted.data(
                      using: .utf8
                  ),
                  let object =
                    try? JSONSerialization.jsonObject(
                        with: data
                    ) as? [String: Any],
                  object["planSHA256"] as? String ==
                    plan.planSHA256,
                  object["projectID"] as? String ==
                    plan.projectID,
                  object["required"] as? Bool == false else {
                return nil
            }
            return object
        }
        if notRequiredObjects.contains(where: {
            $0["policySHA256"] as? NSNull != nil
        }) {
            let project = try store.desiredStates.loadProject(
                id: plan.projectID
            )
            guard project.manifestHash == plan.manifestSHA256 else {
                throw LifecyclePersistedRecoveryError
                    .confirmationMismatch
            }
            return
        }
        let mapping = try recoveryImageProvenanceMapping(
            plan: plan,
            store: store
        )
        let notRequired = notRequiredObjects.contains { object in
            if let mapping {
                return object["policySHA256"] as? String ==
                    mapping.material.policySHA256 &&
                    mapping.policy.requirement == .optional
            }
            return object["policySHA256"] as? NSNull != nil
        }
        guard let mapping,
              mapping.policy.requirement == .required else {
            guard notRequired else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName:
                        recoveryDesiredServices(plan: plan)
                        .values.map(\.logicalServiceName)
                        .sorted().first ?? "unknown"
                )
            }
            return
        }

        let authorizationObjects = allEvents
            .filter {
                $0.type ==
                    "image.provenance.lifecycle.authorized"
            }
            .compactMap { event -> [String: Any]? in
                guard let data =
                        event.payloadJSONRedacted.data(using: .utf8),
                      let object =
                        try? JSONSerialization.jsonObject(
                            with: data
                        ) as? [String: Any],
                      object["planSHA256"] as? String ==
                        plan.planSHA256,
                      object["projectID"] as? String ==
                        plan.projectID,
                      object["policySHA256"] as? String ==
                        mapping.material.policySHA256 else {
                    return nil
                }
                return object
            }
        let desired = Dictionary(
            grouping: recoveryDesiredServices(plan: plan).values,
            by: \.logicalServiceName
        ).compactMapValues(\.first)
        for serviceName in desired.keys.sorted() {
            guard let service = desired[serviceName],
                  let lock = service.imageLock else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
            let records = try store.imageProvenance.loadRecords(
                projectID: plan.projectID,
                serviceName: serviceName,
                descriptorDigest: lock.descriptorDigest,
                policySHA256: mapping.material.policySHA256
            )
            let candidates = authorizationObjects.filter {
                $0["serviceName"] as? String == serviceName &&
                    $0["descriptorDigest"] as? String ==
                        lock.descriptorDigest
            }
            var authorized = false
            for object in candidates {
                guard let recordID = object["recordID"] as? String,
                      let record = records.first(where: {
                          $0.id == recordID
                      }),
                      lifecycleProvenanceEvent(
                          object,
                          exactlyMatches: record
                      ),
                      let current =
                        try lifecycleCurrentProvenanceRecord(
                            records: [record],
                            descriptorDigest:
                                lock.descriptorDigest,
                            policy: mapping.policy,
                            material: mapping.material,
                            store: store,
                            at: Date()
                        ),
                      current.id == record.id else {
                    continue
                }
                authorized = true
                break
            }
            guard authorized else {
                throw recoveryProvenanceSafeHold(
                    plan: plan,
                    serviceName: serviceName
                )
            }
        }
    }

    private func recoveryImageProvenanceMapping(
        plan: LifecyclePlan,
        store: SQLiteStateStore
    ) throws -> ImageProvenancePolicyContext? {
        let project = try store.desiredStates.loadProject(
            id: plan.projectID
        )
        guard project.manifestHash == plan.manifestSHA256,
              let manifestPath = project.manifestPath else {
            throw LifecyclePersistedRecoveryError.unavailable(
                "Recovery cannot resolve the exact persisted manifest for image provenance revalidation."
            )
        }
        let manifestText = try hostwrightReadManifestText(
            path: manifestPath,
            environment: environment
        )
        let validated = try hostwrightValidatedManifest(
            text: manifestText,
            teamProfilePath: nil,
            environment: environment
        )
        guard try lifecycleManifestSHA256(
            text: manifestText,
            manifest: validated.manifest
        ) == plan.manifestSHA256,
              validated.manifest.project.map({
                  "project-\($0)"
              }) == plan.projectID else {
            throw LifecyclePersistedRecoveryError
                .confirmationMismatch
        }
        guard validated.manifest.imageProvenance != nil else {
            return nil
        }
        return try ImageProvenancePolicyMapping.map(
            validated.manifest
        )
    }

    private func recoverySBOMSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .unavailable(
            "Recovery requires the exact previously authorized image SBOM evidence for plan \(plan.planSHA256) and service '\(RuntimeRedactionPolicy.default.redact(serviceName))'. No runtime mutation was attempted."
        )
    }

    private func recoveryTrustSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .safeHold(
            LifecycleRecoverySafeHold(
                reason:
                    "Image trust authorization for recovery is missing, expired, or no longer matches exact evidence.",
                affectedNodeKeys: plan.nodes.filter {
                    (try? LifecycleRevisionCodec
                        .decodeRedactedDesiredJSON(
                            $0.desiredSpecificationJSONRedacted
                        ).logicalServiceName) == serviceName
                }.map(\.key),
                operatorCommands: [
                    "hostwright registry trust status <manifest> --service \(serviceName) --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
    }

    private func recoveryProvenanceSafeHold(
        plan: LifecyclePlan,
        serviceName: String
    ) -> LifecyclePersistedRecoveryError {
        .safeHold(
            LifecycleRecoverySafeHold(
                reason:
                    "Image provenance authorization for recovery is missing, expired, or no longer matches the exact signed attestation.",
                affectedNodeKeys: plan.nodes.filter {
                    (try? LifecycleRevisionCodec
                        .decodeRedactedDesiredJSON(
                            $0.desiredSpecificationJSONRedacted
                        ).logicalServiceName) == serviceName
                }.map(\.key),
                operatorCommands: [
                    "hostwright registry provenance status <manifest> --service \(serviceName) --output json",
                    "hostwright recovery --output json"
                ]
            )
        )
    }
}
