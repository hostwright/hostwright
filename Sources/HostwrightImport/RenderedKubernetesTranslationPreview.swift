import Foundation
import HostwrightManifest

public enum RenderedKubernetesTranslationDiagnosticSeverity: String, Equatable, Sendable {
    case warning
    case error
}

public enum RenderedKubernetesTranslationDiagnosticCode: String, Equatable, Sendable {
    case sourceImportFailed
    case objectLimitExceeded
    case summarySizeExceeded
    case invalidObjectSummary
    case noWorkloads
    case identityNotRepresentable
    case identityCollision
    case multipleContainersUnsupported
    case replicaCountUnsupported
    case selectorTargetMissing
    case selectorTargetAmbiguous
    case selectorResolutionIndeterminate
    case unsupportedServiceProtocol
    case clusterIPServiceUnsupported
    case resourceAdmissionUnavailable
    case untranslatedWorkloadFields
    case manifestValidationFailed
    case canonicalEncodingFailed
    case canonicalRoundTripFailed
    case outputSizeExceeded
}

public struct RenderedKubernetesTranslationDiagnostic: Equatable, Sendable {
    public let code: RenderedKubernetesTranslationDiagnosticCode
    public let severity: RenderedKubernetesTranslationDiagnosticSeverity
    public let documentIndex: Int?
    public let identity: String?
    public let message: String

    public init(
        code: RenderedKubernetesTranslationDiagnosticCode,
        severity: RenderedKubernetesTranslationDiagnosticSeverity,
        documentIndex: Int? = nil,
        identity: String? = nil,
        message: String
    ) {
        self.code = code
        self.severity = severity
        self.documentIndex = documentIndex
        self.identity = identity
        self.message = message
    }

    public var rendered: String {
        var context: [String] = []
        if let documentIndex {
            context.append("document \(documentIndex)")
        }
        if let identity {
            context.append(identity)
        }
        let suffix = context.isEmpty ? "" : " (\(context.joined(separator: ", ")))"
        return "\(code.rawValue): \(severity.rawValue)\(suffix): \(message)"
    }
}

public struct RenderedKubernetesUntranslatedField: Equatable, Sendable {
    public let documentIndex: Int
    public let identity: String
    public let path: String
    public let reason: String

    public init(
        documentIndex: Int,
        identity: String,
        path: String,
        reason: String
    ) {
        self.documentIndex = documentIndex
        self.identity = identity
        self.path = path
        self.reason = reason
    }
}

public struct RenderedKubernetesTranslationPreviewResult: Equatable, Sendable {
    public let manifest: HostwrightManifest?
    public let manifestText: String?
    public let diagnostics: [RenderedKubernetesTranslationDiagnostic]
    public let untranslated: [RenderedKubernetesUntranslatedField]

    public init(
        manifest: HostwrightManifest?,
        manifestText: String?,
        diagnostics: [RenderedKubernetesTranslationDiagnostic],
        untranslated: [RenderedKubernetesUntranslatedField]
    ) {
        self.manifest = manifest
        self.manifestText = manifestText
        self.diagnostics = diagnostics
        self.untranslated = untranslated
    }

    public var canonicalManifestText: String? {
        manifestText
    }

    public var warnings: [RenderedKubernetesTranslationDiagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }

    public var errors: [RenderedKubernetesTranslationDiagnostic] {
        diagnostics.filter { $0.severity == .error }
    }

    public var succeeded: Bool {
        errors.isEmpty && manifest != nil && manifestText != nil
    }
}

public enum RenderedKubernetesTranslationPreview {
    public static let maximumObjects = RenderedKubernetesImporter.maximumDocuments
    public static let maximumSummaryBytes = RenderedKubernetesImporter.maximumInputBytes
    public static let maximumOutputBytes = RenderedKubernetesImporter.maximumInputBytes
    public static let defaultProject = "kubernetes-preview"

    public static func translate(
        _ importResult: RenderedKubernetesImportResult,
        project: String = "kubernetes-preview"
    ) -> RenderedKubernetesTranslationPreviewResult {
        guard importResult.succeeded else {
            let first = importResult.diagnostics.first
            return failed([
                diagnostic(
                    .sourceImportFailed,
                    documentIndex: first?.documentIndex,
                    message: "Translation requires a successful rendered Kubernetes scan; the source result contains \(importResult.diagnostics.count) diagnostic(s)."
                ),
            ])
        }
        guard importResult.objects.count <= maximumObjects else {
            return failed([
                diagnostic(
                    .objectLimitExceeded,
                    message: "Translation accepts at most \(maximumObjects) immutable object summaries."
                ),
            ])
        }
        guard summariesFitBound(importResult.objects) else {
            return failed([
                diagnostic(
                    .summarySizeExceeded,
                    message: "Immutable object summaries exceed the \(maximumSummaryBytes)-byte translation bound."
                ),
            ])
        }
        guard !importResult.objects.isEmpty else {
            return failed([
                diagnostic(
                    .noWorkloads,
                    message: "Translation requires at least one supported Pod or Deployment summary."
                ),
            ])
        }
        guard importResult.objects.contains(where: {
            $0.kind == .pod || $0.kind == .deployment
        }) else {
            return failed([
                diagnostic(
                    .noWorkloads,
                    message: "Translation requires at least one supported Pod or Deployment summary."
                ),
            ])
        }

        let objects = importResult.objects.sorted(by: objectOrder)
        var diagnostics: [RenderedKubernetesTranslationDiagnostic] = []
        var untranslated: [RenderedKubernetesUntranslatedField] = []
        var workloads: [Workload] = []
        var services: [RenderedKubernetesObjectSummary] = []
        var documentIndexes: Set<Int> = []
        var firstWorkloadByServiceName: [String: Workload] = [:]

        for object in objects {
            let identity = objectIdentity(object)
            guard object.documentIndex > 0,
                  documentIndexes.insert(object.documentIndex).inserted else {
                diagnostics.append(
                    diagnostic(
                        .invalidObjectSummary,
                        documentIndex: object.documentIndex,
                        identity: identity,
                        message: "Every immutable object summary must have a unique positive document index."
                    )
                )
                continue
            }
            if let failure = structuralFailure(object) {
                diagnostics.append(
                    diagnostic(
                        .invalidObjectSummary,
                        documentIndex: object.documentIndex,
                        identity: identity,
                        message: failure
                    )
                )
                continue
            }

            switch object.kind {
            case .service:
                services.append(object)
            case .pod, .deployment:
                guard object.containers.count == 1 else {
                    diagnostics.append(
                        diagnostic(
                            .multipleContainersUnsupported,
                            documentIndex: object.documentIndex,
                            identity: identity,
                            message: "Translation requires exactly one container; this workload contains \(object.containers.count)."
                        )
                    )
                    continue
                }

                let replicas = object.kind == .deployment ? object.replicas ?? 0 : 1
                guard (1...256).contains(replicas) else {
                    diagnostics.append(
                        diagnostic(
                            .replicaCountUnsupported,
                            documentIndex: object.documentIndex,
                            identity: identity,
                            message: "Deployment replicas \(replicas) cannot be represented; Hostwright requires 1...256 replicas and does not silently scale zero to one."
                        )
                    )
                    continue
                }

                let selectorLabels = object.kind == .deployment ? object.selector : object.labels
                guard let labelValues = uniqueLabels(selectorLabels) else {
                    diagnostics.append(
                        diagnostic(
                            .invalidObjectSummary,
                            documentIndex: object.documentIndex,
                            identity: identity,
                            message: "Workload selector labels contain duplicate keys."
                        )
                    )
                    continue
                }
                guard let serviceName = mappedServiceName(object) else {
                    diagnostics.append(
                        diagnostic(
                            .identityNotRepresentable,
                            documentIndex: object.documentIndex,
                            identity: identity,
                            message: "Namespace/name cannot map to a Hostwright DNS-label service name. Default-namespace names are preserved; other names use '<namespace>-<name>' and must remain at most 63 bytes."
                        )
                    )
                    continue
                }

                let workload = Workload(
                    object: object,
                    identity: identity,
                    serviceName: serviceName,
                    selectorLabels: labelValues,
                    replicas: replicas
                )
                if let existing = firstWorkloadByServiceName[serviceName] {
                    diagnostics.append(
                        diagnostic(
                            .identityCollision,
                            documentIndex: object.documentIndex,
                            identity: identity,
                            message: "Workload identities '\(existing.identity)' and '\(identity)' both map to Hostwright service '\(serviceName)'."
                        )
                    )
                } else {
                    firstWorkloadByServiceName[serviceName] = workload
                }
                workloads.append(workload)
                appendUntranslatedFields(for: workload, to: &untranslated)
                diagnostics.append(
                    RenderedKubernetesTranslationDiagnostic(
                        code: .untranslatedWorkloadFields,
                        severity: .warning,
                        documentIndex: object.documentIndex,
                        identity: identity,
                        message: "The preview emits only workload image, identity, and replicas; container-name and Kubernetes label/selector semantics remain explicitly untranslated."
                    )
                )
            }
        }

        for service in services {
            evaluate(service: service, against: workloads, diagnostics: &diagnostics)
        }

        guard !diagnostics.contains(where: { $0.severity == .error }) else {
            return failed(diagnostics, untranslated: untranslated)
        }
        guard !workloads.isEmpty else {
            diagnostics.append(
                diagnostic(
                    .noWorkloads,
                    message: "Translation requires at least one supported Pod or Deployment summary."
                )
            )
            return failed(diagnostics, untranslated: untranslated)
        }

        // The immutable scanner summary intentionally does not retain Kubernetes
        // resource requests or limits. Manifest v3 requires an explicit,
        // validated CPU and memory request/limit pair, so a preview cannot
        // safely invent capacity or claim that a resource-less workload is
        // executable.
        diagnostics.append(
            diagnostic(
                .resourceAdmissionUnavailable,
                message: "The scanner summary contains no validated compute-resource admission. Manifest v3 requires explicit CPU and memory requests and limits, so translation emits no Hostwright manifest."
            )
        )
        return failed(diagnostics, untranslated: untranslated)
    }

    private static func evaluate(
        service: RenderedKubernetesObjectSummary,
        against workloads: [Workload],
        diagnostics: inout [RenderedKubernetesTranslationDiagnostic]
    ) {
        let identity = objectIdentity(service)
        guard let selector = uniqueLabels(service.selector) else {
            diagnostics.append(
                diagnostic(
                    .invalidObjectSummary,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service selector contains duplicate keys."
                )
            )
            return
        }
        var matches: [Workload] = []
        var indeterminate: [Workload] = []
        for workload in workloads where workload.object.namespace == service.namespace {
            switch matchCertainty(selector: selector, workload: workload) {
            case .proven:
                matches.append(workload)
            case .excluded:
                break
            case .indeterminate:
                indeterminate.append(workload)
            }
        }
        matches.sort { $0.identity < $1.identity }
        indeterminate.sort { $0.identity < $1.identity }

        if matches.count > 1 {
            diagnostics.append(
                diagnostic(
                    .selectorTargetAmbiguous,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service selector resolves multiple translated workloads: \(matches.map(\.identity).joined(separator: ", "))."
                )
            )
            return
        }
        if !indeterminate.isEmpty {
            let proven = matches.first.map { " Proven match: \($0.identity)." } ?? ""
            diagnostics.append(
                diagnostic(
                    .selectorResolutionIndeterminate,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service selector cannot be resolved from immutable summaries because Deployment template labels beyond matchLabels are not retained. Indeterminate workload(s): \(indeterminate.map(\.identity).joined(separator: ", ")).\(proven)"
                )
            )
            return
        }
        guard !matches.isEmpty else {
            diagnostics.append(
                diagnostic(
                    .selectorTargetMissing,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service selector does not resolve a translated workload in namespace '\(service.namespace)'."
                )
            )
            return
        }

        let ports = service.servicePorts.sorted(by: portOrder)
        if let invalid = ports.first(where: {
            !(1...65_535).contains($0.port) || !(1...65_535).contains($0.targetPort)
        }) {
            diagnostics.append(
                diagnostic(
                    .invalidObjectSummary,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service port \(invalid.port) -> targetPort \(invalid.targetPort) falls outside 1...65535."
                )
            )
            return
        }
        if let unsupported = ports.first(where: {
            $0.protocolName != "TCP" && $0.protocolName != "UDP"
        }) {
            diagnostics.append(
                diagnostic(
                    .unsupportedServiceProtocol,
                    documentIndex: service.documentIndex,
                    identity: identity,
                    message: "Service protocol '\(unsupported.protocolName)' has no supported exact preview mapping."
                )
            )
            return
        }

        let mappings = ports.map {
            "\($0.port)/\($0.protocolName) -> \($0.targetPort)"
        }.joined(separator: ", ")
        diagnostics.append(
            diagnostic(
                .clusterIPServiceUnsupported,
                documentIndex: service.documentIndex,
                identity: identity,
                message: "ClusterIP mapping [\(mappings)] targets '\(matches[0].identity)', but Hostwright has no internal-only service endpoint construct; the preview refuses to publish a host endpoint or silently drop the Service."
            )
        )
    }

    private static func structuralFailure(
        _ object: RenderedKubernetesObjectSummary
    ) -> String? {
        switch object.kind {
        case .pod:
            guard object.apiVersion == "v1" else {
                return "Pod summaries require apiVersion 'v1'."
            }
            guard object.replicas == nil,
                  object.selector.isEmpty,
                  object.servicePorts.isEmpty else {
                return "Pod summary fields do not match the successful scanner contract."
            }
        case .deployment:
            guard object.apiVersion == "apps/v1" else {
                return "Deployment summaries require apiVersion 'apps/v1'."
            }
            guard object.replicas != nil,
                  !object.selector.isEmpty,
                  object.servicePorts.isEmpty else {
                return "Deployment summary fields do not match the successful scanner contract."
            }
        case .service:
            guard object.apiVersion == "v1" else {
                return "Service summaries require apiVersion 'v1'."
            }
            guard object.containers.isEmpty,
                  object.replicas == nil,
                  !object.selector.isEmpty,
                  !object.servicePorts.isEmpty else {
                return "Service summary fields do not match the successful ClusterIP scanner contract."
            }
        }
        guard uniqueLabels(object.labels) != nil,
              uniqueLabels(object.selector) != nil else {
            return "Object summary label maps contain duplicate keys."
        }
        return nil
    }

    private static func matchCertainty(
        selector: [String: String],
        workload: Workload
    ) -> SelectorMatchCertainty {
        if workload.object.kind == .pod {
            return selector.allSatisfy { workload.selectorLabels[$0.key] == $0.value }
                ? .proven
                : .excluded
        }

        var missingRetainedLabel = false
        for (key, value) in selector {
            if let retained = workload.selectorLabels[key] {
                if retained != value {
                    return .excluded
                }
            } else {
                missingRetainedLabel = true
            }
        }
        return missingRetainedLabel ? .indeterminate : .proven
    }

    private static func appendUntranslatedFields(
        for workload: Workload,
        to fields: inout [RenderedKubernetesUntranslatedField]
    ) {
        if !workload.object.labels.isEmpty {
            fields.append(
                RenderedKubernetesUntranslatedField(
                    documentIndex: workload.object.documentIndex,
                    identity: workload.identity,
                    path: "$.metadata.labels",
                    reason: "Hostwright labels do not provide Kubernetes workload-label semantics, so metadata labels are not emitted."
                )
            )
        }
        if workload.object.kind == .deployment {
            fields.append(
                RenderedKubernetesUntranslatedField(
                    documentIndex: workload.object.documentIndex,
                    identity: workload.identity,
                    path: "$.spec.selector.matchLabels",
                    reason: "Deployment selector labels are used only for offline Service resolution and are not emitted."
                )
            )
            fields.append(
                RenderedKubernetesUntranslatedField(
                    documentIndex: workload.object.documentIndex,
                    identity: workload.identity,
                    path: "$.spec.template.metadata.labels",
                    reason: "Deployment template labels beyond matchLabels are not retained by the immutable scanner summary."
                )
            )
        }
        let containerPath = workload.object.kind == .deployment
            ? "$.spec.template.spec.containers[0].name"
            : "$.spec.containers[0].name"
        fields.append(
            RenderedKubernetesUntranslatedField(
                documentIndex: workload.object.documentIndex,
                identity: workload.identity,
                path: containerPath,
                reason: "Hostwright names the translated workload service and has no separate one-container identity field."
            )
        )
    }

    private static func mappedServiceName(
        _ object: RenderedKubernetesObjectSummary
    ) -> String? {
        let candidate = object.namespace == "default"
            ? object.name
            : "\(object.namespace)-\(object.name)"
        guard candidate.utf8.count <= 63,
              candidate.range(
                  of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        return candidate
    }

    private static func uniqueLabels(
        _ labels: [RenderedKubernetesKeyValueSummary]
    ) -> [String: String]? {
        var result: [String: String] = [:]
        for label in labels {
            guard result[label.key] == nil else {
                return nil
            }
            result[label.key] = label.value
        }
        return result
    }

    private static func summariesFitBound(
        _ objects: [RenderedKubernetesObjectSummary]
    ) -> Bool {
        var total = 0
        for object in objects {
            var strings = [object.apiVersion, object.name, object.namespace]
            strings.append(contentsOf: object.labels.flatMap { [$0.key, $0.value] })
            strings.append(contentsOf: object.containers.flatMap { [$0.name, $0.image] })
            strings.append(contentsOf: object.selector.flatMap { [$0.key, $0.value] })
            strings.append(contentsOf: object.servicePorts.flatMap { port in
                [port.name ?? "", port.protocolName]
            })
            for value in strings {
                let count = value.utf8.count
                guard count <= maximumSummaryBytes - total else {
                    return false
                }
                total += count
            }
        }
        return true
    }

    private static func objectIdentity(
        _ object: RenderedKubernetesObjectSummary
    ) -> String {
        "\(object.kind.rawValue)/\(object.namespace)/\(object.name)"
    }

    private static func failed(
        _ diagnostics: [RenderedKubernetesTranslationDiagnostic],
        untranslated: [RenderedKubernetesUntranslatedField] = []
    ) -> RenderedKubernetesTranslationPreviewResult {
        RenderedKubernetesTranslationPreviewResult(
            manifest: nil,
            manifestText: nil,
            diagnostics: diagnostics.sorted(by: diagnosticOrder),
            untranslated: untranslated.sorted(by: untranslatedOrder)
        )
    }

    private static func diagnostic(
        _ code: RenderedKubernetesTranslationDiagnosticCode,
        documentIndex: Int? = nil,
        identity: String? = nil,
        message: String
    ) -> RenderedKubernetesTranslationDiagnostic {
        RenderedKubernetesTranslationDiagnostic(
            code: code,
            severity: .error,
            documentIndex: documentIndex,
            identity: identity,
            message: message
        )
    }

    private static func objectOrder(
        _ lhs: RenderedKubernetesObjectSummary,
        _ rhs: RenderedKubernetesObjectSummary
    ) -> Bool {
        if lhs.documentIndex != rhs.documentIndex {
            return lhs.documentIndex < rhs.documentIndex
        }
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        if lhs.namespace != rhs.namespace {
            return lhs.namespace < rhs.namespace
        }
        return lhs.name < rhs.name
    }

    private static func portOrder(
        _ lhs: RenderedKubernetesServicePortSummary,
        _ rhs: RenderedKubernetesServicePortSummary
    ) -> Bool {
        if lhs.port != rhs.port {
            return lhs.port < rhs.port
        }
        if lhs.protocolName != rhs.protocolName {
            return lhs.protocolName < rhs.protocolName
        }
        if lhs.targetPort != rhs.targetPort {
            return lhs.targetPort < rhs.targetPort
        }
        return (lhs.name ?? "") < (rhs.name ?? "")
    }

    private static func diagnosticOrder(
        _ lhs: RenderedKubernetesTranslationDiagnostic,
        _ rhs: RenderedKubernetesTranslationDiagnostic
    ) -> Bool {
        if lhs.severity != rhs.severity {
            return lhs.severity == .error
        }
        let lhsDocument = lhs.documentIndex ?? Int.max
        let rhsDocument = rhs.documentIndex ?? Int.max
        if lhsDocument != rhsDocument {
            return lhsDocument < rhsDocument
        }
        if lhs.code.rawValue != rhs.code.rawValue {
            return lhs.code.rawValue < rhs.code.rawValue
        }
        if lhs.identity != rhs.identity {
            return (lhs.identity ?? "") < (rhs.identity ?? "")
        }
        return lhs.message < rhs.message
    }

    private static func untranslatedOrder(
        _ lhs: RenderedKubernetesUntranslatedField,
        _ rhs: RenderedKubernetesUntranslatedField
    ) -> Bool {
        if lhs.documentIndex != rhs.documentIndex {
            return lhs.documentIndex < rhs.documentIndex
        }
        if lhs.identity != rhs.identity {
            return lhs.identity < rhs.identity
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.reason < rhs.reason
    }
}

private struct Workload {
    let object: RenderedKubernetesObjectSummary
    let identity: String
    let serviceName: String
    let selectorLabels: [String: String]
    let replicas: Int
}

private enum SelectorMatchCertainty {
    case proven
    case excluded
    case indeterminate
}
