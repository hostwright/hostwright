import Foundation

public enum RuntimeProviderRecoveryDisposition: String, Codable, Equatable, Sendable {
    case resumeFromCheckpoint = "resume-from-checkpoint"
    case reobserveThenResumeFromCheckpoint = "reobserve-then-resume-from-checkpoint"
    case refuseAndPreserveCheckpoint = "refuse-and-preserve-checkpoint"
}

public enum RuntimeProviderRecoveryChangeKind: String, Codable, CaseIterable, Equatable, Sendable {
    case capabilityDigest = "capability-digest"
    case componentAdded = "component-added"
    case componentBuild = "component-build"
    case componentFingerprint = "component-fingerprint"
    case componentRemoved = "component-removed"
    case componentVersion = "component-version"
    case hostArchitecture = "host-architecture"
    case macOSBuild = "macos-build"
    case macOSVersion = "macos-version"
    case providerAPI = "provider-api"
    case providerID = "provider-id"
    case snapshotSchema = "snapshot-schema"
}

public struct RuntimeProviderRecoveryChange: Codable, Equatable, Sendable {
    public let kind: RuntimeProviderRecoveryChangeKind
    public let component: RuntimeProviderComponentID?
    public let previousValue: String
    public let currentValue: String

    public init(
        kind: RuntimeProviderRecoveryChangeKind,
        component: RuntimeProviderComponentID? = nil,
        previousValue: String,
        currentValue: String
    ) {
        self.kind = kind
        self.component = component
        self.previousValue = previousValue
        self.currentValue = currentValue
    }
}

public enum RuntimeProviderRecoveryFindingReason: String, Codable, Equatable, Sendable {
    case incompatibleSnapshot = "incompatible-snapshot"
    case invalidMetadataSupport = "invalid-metadata-support"
    case invalidProviderGeneration = "invalid-provider-generation"
    case invalidStateSchema = "invalid-state-schema"
    case metadataRevisionTooNew = "metadata-revision-too-new"
    case metadataRevisionTooOld = "metadata-revision-too-old"
    case mixedComponents = "mixed-components"
    case providerMismatch = "provider-mismatch"
    case unsupportedFutureProtocol = "unsupported-future-protocol"
    case unknownProviderBinding = "unknown-provider-binding"
}

public struct RuntimeProviderRecoveryFinding: Codable, Equatable, Sendable {
    public let reason: RuntimeProviderRecoveryFindingReason
    public let component: RuntimeProviderComponentID?
    public let expectedValue: String
    public let actualValue: String

    public init(
        reason: RuntimeProviderRecoveryFindingReason,
        component: RuntimeProviderComponentID? = nil,
        expectedValue: String,
        actualValue: String
    ) {
        self.reason = reason
        self.component = component
        self.expectedValue = expectedValue
        self.actualValue = actualValue
    }
}

public struct RuntimeProviderRecoveryFingerprint: Codable, Equatable, Sendable {
    public let snapshotSchemaVersion: Int
    public let descriptor: RuntimeProviderDescriptor
    public let host: RuntimeProviderHostPlatform
    public let capabilitySHA256: String

    public init(snapshot: RuntimeCapabilitySnapshot) {
        snapshotSchemaVersion = snapshot.schemaVersion
        descriptor = snapshot.descriptor
        host = snapshot.host
        capabilitySHA256 = snapshot.canonicalSHA256
    }
}

public struct RuntimeProviderRecoveryRecord: Codable, Equatable, Sendable {
    public static let requiredStateSchemaVersion = 7

    public let stateSchemaVersion: Int
    public let persistedProviderBinding: String
    public let providerGeneration: Int
    public let providerMetadataRevision: Int
    public let fingerprint: RuntimeProviderRecoveryFingerprint

    public init(
        stateSchemaVersion: Int = RuntimeProviderRecoveryRecord.requiredStateSchemaVersion,
        persistedProviderBinding: String,
        providerGeneration: Int,
        providerMetadataRevision: Int,
        fingerprint: RuntimeProviderRecoveryFingerprint
    ) {
        self.stateSchemaVersion = stateSchemaVersion
        self.persistedProviderBinding = persistedProviderBinding
        self.providerGeneration = providerGeneration
        self.providerMetadataRevision = providerMetadataRevision
        self.fingerprint = fingerprint
    }
}

public struct RuntimeProviderMetadataSupport: Codable, Equatable, Sendable {
    public let minimumReadableRevision: Int
    public let currentWritableRevision: Int

    public init(minimumReadableRevision: Int, currentWritableRevision: Int) {
        self.minimumReadableRevision = minimumReadableRevision
        self.currentWritableRevision = currentWritableRevision
    }
}

public enum RuntimeProviderBindingRecoveryDecision: Equatable, Sendable {
    case stable(RuntimeProviderID)
    case migrateLegacy(from: String, to: RuntimeProviderID)
    case refuseUnknown(String)

    public var stableProviderID: RuntimeProviderID? {
        switch self {
        case .stable(let providerID), .migrateLegacy(_, let providerID):
            return providerID
        case .refuseUnknown:
            return nil
        }
    }
}

public struct RuntimeProviderRecoveryEvaluation: Equatable, Sendable {
    public let bindingDecision: RuntimeProviderBindingRecoveryDecision
    public let disposition: RuntimeProviderRecoveryDisposition
    public let changes: [RuntimeProviderRecoveryChange]
    public let findings: [RuntimeProviderRecoveryFinding]
    public let invalidatesCapabilitySnapshot: Bool
    public let providerGeneration: Int
    public let nextProviderMetadataRevision: Int

    public init(
        bindingDecision: RuntimeProviderBindingRecoveryDecision,
        disposition: RuntimeProviderRecoveryDisposition,
        changes: [RuntimeProviderRecoveryChange],
        findings: [RuntimeProviderRecoveryFinding],
        invalidatesCapabilitySnapshot: Bool,
        providerGeneration: Int,
        nextProviderMetadataRevision: Int
    ) {
        self.bindingDecision = bindingDecision
        self.disposition = disposition
        self.changes = changes
        self.findings = findings
        self.invalidatesCapabilitySnapshot = invalidatesCapabilitySnapshot
        self.providerGeneration = providerGeneration
        self.nextProviderMetadataRevision = nextProviderMetadataRevision
    }
}

public enum RuntimeProviderRecoveryEvaluator {
    public static func evaluate(
        record: RuntimeProviderRecoveryRecord,
        currentSnapshot: RuntimeCapabilitySnapshot,
        metadataSupport: RuntimeProviderMetadataSupport,
        freshPersistedEvidence: RuntimeProviderMetadataEvidence? = nil
    ) -> RuntimeProviderRecoveryEvaluation {
        let bindingDecision = bindingDecision(for: record.persistedProviderBinding)
        let changes = changes(
            from: record.fingerprint,
            to: RuntimeProviderRecoveryFingerprint(snapshot: currentSnapshot)
        )
        var findings: [RuntimeProviderRecoveryFinding] = []

        if record.stateSchemaVersion != RuntimeProviderRecoveryRecord.requiredStateSchemaVersion {
            findings.append(
                RuntimeProviderRecoveryFinding(
                    reason: .invalidStateSchema,
                    expectedValue: String(RuntimeProviderRecoveryRecord.requiredStateSchemaVersion),
                    actualValue: String(record.stateSchemaVersion)
                )
            )
        }
        if record.providerGeneration <= 0 {
            findings.append(
                RuntimeProviderRecoveryFinding(
                    reason: .invalidProviderGeneration,
                    expectedValue: "positive",
                    actualValue: String(record.providerGeneration)
                )
            )
        }

        guard let stableProviderID = bindingDecision.stableProviderID else {
            findings.append(
                RuntimeProviderRecoveryFinding(
                    reason: .unknownProviderBinding,
                    expectedValue: RuntimeProviderID.knownValues.map(\.rawValue).sorted().joined(separator: ","),
                    actualValue: record.persistedProviderBinding
                )
            )
            return evaluation(
                record: record,
                currentSnapshot: currentSnapshot,
                metadataSupport: metadataSupport,
                freshPersistedEvidence: freshPersistedEvidence,
                bindingDecision: bindingDecision,
                changes: changes,
                findings: findings
            )
        }

        if record.fingerprint.descriptor.providerID != stableProviderID {
            findings.append(
                RuntimeProviderRecoveryFinding(
                    reason: .providerMismatch,
                    expectedValue: stableProviderID.rawValue,
                    actualValue: record.fingerprint.descriptor.providerID.rawValue
                )
            )
        }
        if currentSnapshot.descriptor.providerID != stableProviderID {
            findings.append(
                RuntimeProviderRecoveryFinding(
                    reason: .providerMismatch,
                    expectedValue: stableProviderID.rawValue,
                    actualValue: currentSnapshot.descriptor.providerID.rawValue
                )
            )
        }

        findings += compatibilityFindings(for: currentSnapshot)
        findings += metadataFindings(record: record, support: metadataSupport)

        return evaluation(
            record: record,
            currentSnapshot: currentSnapshot,
            metadataSupport: metadataSupport,
            freshPersistedEvidence: freshPersistedEvidence,
            bindingDecision: bindingDecision,
            changes: changes,
            findings: findings
        )
    }

    public static func bindingDecision(
        for persistedValue: String
    ) -> RuntimeProviderBindingRecoveryDecision {
        guard let providerID = RuntimeProviderBinding.stableID(for: persistedValue) else {
            return .refuseUnknown(persistedValue)
        }
        if persistedValue == providerID.rawValue {
            return .stable(providerID)
        }
        return .migrateLegacy(from: persistedValue, to: providerID)
    }

    public static func changes(
        from previous: RuntimeProviderRecoveryFingerprint,
        to current: RuntimeProviderRecoveryFingerprint
    ) -> [RuntimeProviderRecoveryChange] {
        var result: [RuntimeProviderRecoveryChange] = []
        appendChange(
            to: &result,
            kind: .snapshotSchema,
            previous: String(previous.snapshotSchemaVersion),
            current: String(current.snapshotSchemaVersion)
        )
        appendChange(
            to: &result,
            kind: .providerAPI,
            previous: String(previous.descriptor.providerAPIVersion),
            current: String(current.descriptor.providerAPIVersion)
        )
        appendChange(
            to: &result,
            kind: .providerID,
            previous: previous.descriptor.providerID.rawValue,
            current: current.descriptor.providerID.rawValue
        )
        appendChange(
            to: &result,
            kind: .macOSVersion,
            previous: versionString(previous.host.macOSVersion),
            current: versionString(current.host.macOSVersion)
        )
        appendChange(
            to: &result,
            kind: .macOSBuild,
            previous: previous.host.macOSBuild,
            current: current.host.macOSBuild
        )
        appendChange(
            to: &result,
            kind: .hostArchitecture,
            previous: previous.host.architecture.rawValue,
            current: current.host.architecture.rawValue
        )

        let previousComponents = componentMap(previous.descriptor.components)
        let currentComponents = componentMap(current.descriptor.components)
        for identifier in Set(previousComponents.keys).union(currentComponents.keys) {
            switch (previousComponents[identifier], currentComponents[identifier]) {
            case (.some(let old), .some(let new)):
                appendChange(
                    to: &result,
                    kind: .componentVersion,
                    component: identifier,
                    previous: old.version,
                    current: new.version
                )
                appendChange(
                    to: &result,
                    kind: .componentBuild,
                    component: identifier,
                    previous: old.build,
                    current: new.build
                )
                appendChange(
                    to: &result,
                    kind: .componentFingerprint,
                    component: identifier,
                    previous: old.fingerprint,
                    current: new.fingerprint
                )
            case (.some(let old), .none):
                result.append(
                    RuntimeProviderRecoveryChange(
                        kind: .componentRemoved,
                        component: identifier,
                        previousValue: componentSummary(old),
                        currentValue: "absent"
                    )
                )
            case (.none, .some(let new)):
                result.append(
                    RuntimeProviderRecoveryChange(
                        kind: .componentAdded,
                        component: identifier,
                        previousValue: "absent",
                        currentValue: componentSummary(new)
                    )
                )
            case (.none, .none):
                break
            }
        }
        appendChange(
            to: &result,
            kind: .capabilityDigest,
            previous: previous.capabilitySHA256,
            current: current.capabilitySHA256
        )
        return result.sorted(by: changeOrder)
    }

    private static func evaluation(
        record: RuntimeProviderRecoveryRecord,
        currentSnapshot: RuntimeCapabilitySnapshot,
        metadataSupport: RuntimeProviderMetadataSupport,
        freshPersistedEvidence: RuntimeProviderMetadataEvidence?,
        bindingDecision: RuntimeProviderBindingRecoveryDecision,
        changes: [RuntimeProviderRecoveryChange],
        findings: [RuntimeProviderRecoveryFinding]
    ) -> RuntimeProviderRecoveryEvaluation {
        let orderedFindings = findings.sorted(by: findingOrder)
        let refused = !orderedFindings.isEmpty
        let disposition: RuntimeProviderRecoveryDisposition
        if refused {
            disposition = .refuseAndPreserveCheckpoint
        } else if changes.isEmpty {
            disposition = .resumeFromCheckpoint
        } else {
            disposition = .reobserveThenResumeFromCheckpoint
        }
        return RuntimeProviderRecoveryEvaluation(
            bindingDecision: bindingDecision,
            disposition: disposition,
            changes: changes,
            findings: orderedFindings,
            invalidatesCapabilitySnapshot: !changes.isEmpty || refused,
            providerGeneration: record.providerGeneration,
            nextProviderMetadataRevision: shouldAdvanceMetadataRevision(
                record: record,
                currentSnapshot: currentSnapshot,
                metadataSupport: metadataSupport,
                freshPersistedEvidence: freshPersistedEvidence,
                refused: refused
            ) ? metadataSupport.currentWritableRevision : record.providerMetadataRevision
        )
    }

    private static func shouldAdvanceMetadataRevision(
        record: RuntimeProviderRecoveryRecord,
        currentSnapshot: RuntimeCapabilitySnapshot,
        metadataSupport: RuntimeProviderMetadataSupport,
        freshPersistedEvidence: RuntimeProviderMetadataEvidence?,
        refused: Bool
    ) -> Bool {
        guard !refused,
              record.providerMetadataRevision < metadataSupport.currentWritableRevision,
              let freshPersistedEvidence,
              !freshPersistedEvidence.isLegacy,
              freshPersistedEvidence.providerMetadataRevision == metadataSupport.currentWritableRevision,
              freshPersistedEvidence.capabilitySHA256 == currentSnapshot.canonicalSHA256 else {
            return false
        }
        return true
    }

    private static func compatibilityFindings(
        for snapshot: RuntimeCapabilitySnapshot
    ) -> [RuntimeProviderRecoveryFinding] {
        RuntimeProviderCapabilityNegotiator.validationFindings(for: snapshot).map { finding in
            let reason: RuntimeProviderRecoveryFindingReason
            if finding.reason == .componentMixed {
                reason = .mixedComponents
            } else if finding.reason == .componentVersionUnsupported,
                      finding.component == .containerizationHelperProtocolV1 {
                reason = .unsupportedFutureProtocol
            } else {
                reason = .incompatibleSnapshot
            }
            return RuntimeProviderRecoveryFinding(
                reason: reason,
                component: finding.component,
                expectedValue: "supported-runtime-provider-contract",
                actualValue: finding.reason.rawValue
            )
        }
    }

    private static func metadataFindings(
        record: RuntimeProviderRecoveryRecord,
        support: RuntimeProviderMetadataSupport
    ) -> [RuntimeProviderRecoveryFinding] {
        guard support.minimumReadableRevision > 0,
              support.currentWritableRevision >= support.minimumReadableRevision else {
            return [
                RuntimeProviderRecoveryFinding(
                    reason: .invalidMetadataSupport,
                    expectedValue: "0 < minimum-readable <= current-writable",
                    actualValue: "\(support.minimumReadableRevision)...\(support.currentWritableRevision)"
                )
            ]
        }
        if record.providerMetadataRevision < support.minimumReadableRevision {
            return [
                RuntimeProviderRecoveryFinding(
                    reason: .metadataRevisionTooOld,
                    expectedValue: String(support.minimumReadableRevision),
                    actualValue: String(record.providerMetadataRevision)
                )
            ]
        }
        if record.providerMetadataRevision > support.currentWritableRevision {
            return [
                RuntimeProviderRecoveryFinding(
                    reason: .metadataRevisionTooNew,
                    expectedValue: String(support.currentWritableRevision),
                    actualValue: String(record.providerMetadataRevision)
                )
            ]
        }
        return []
    }

    private static func appendChange(
        to changes: inout [RuntimeProviderRecoveryChange],
        kind: RuntimeProviderRecoveryChangeKind,
        component: RuntimeProviderComponentID? = nil,
        previous: String,
        current: String
    ) {
        guard previous != current else { return }
        changes.append(
            RuntimeProviderRecoveryChange(
                kind: kind,
                component: component,
                previousValue: previous,
                currentValue: current
            )
        )
    }

    private static func componentSummary(_ component: RuntimeProviderComponent) -> String {
        "\(component.version)|\(component.build)|\(component.fingerprint)"
    }

    private static func componentMap(
        _ components: [RuntimeProviderComponent]
    ) -> [RuntimeProviderComponentID: RuntimeProviderComponent] {
        var result: [RuntimeProviderComponentID: RuntimeProviderComponent] = [:]
        for component in components where result[component.identifier] == nil {
            result[component.identifier] = component
        }
        return result
    }

    private static func versionString(_ version: RuntimeProviderMacOSVersion) -> String {
        "\(version.major).\(version.minor).\(version.patch)"
    }

    private static func changeOrder(
        _ lhs: RuntimeProviderRecoveryChange,
        _ rhs: RuntimeProviderRecoveryChange
    ) -> Bool {
        (lhs.kind.rawValue, lhs.component?.rawValue ?? "", lhs.previousValue, lhs.currentValue) <
            (rhs.kind.rawValue, rhs.component?.rawValue ?? "", rhs.previousValue, rhs.currentValue)
    }

    private static func findingOrder(
        _ lhs: RuntimeProviderRecoveryFinding,
        _ rhs: RuntimeProviderRecoveryFinding
    ) -> Bool {
        (lhs.reason.rawValue, lhs.component?.rawValue ?? "", lhs.expectedValue, lhs.actualValue) <
            (rhs.reason.rawValue, rhs.component?.rawValue ?? "", rhs.expectedValue, rhs.actualValue)
    }
}
