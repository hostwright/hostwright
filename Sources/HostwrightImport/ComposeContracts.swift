import Foundation
import HostwrightManifest

public enum ComposeContractVersion {
    public static let value = "v1"
    public static let schemaVersion = 1
}

public enum ComposeOperation: String, Codable, Equatable, Sendable {
    case importing = "import"
    case exporting = "export"
    case updatePlanning = "update-plan"
}

public enum ComposeLossSeverity: String, Codable, Equatable, Sendable {
    case warning
    case error
}

public enum ComposeLossCode: String, Codable, Equatable, Sendable {
    case unsupportedInput = "HW-COMPOSE-001"
    case invalidInput = "HW-COMPOSE-002"
    case exportLoss = "HW-COMPOSE-003"
    case invalidManifest = "HW-COMPOSE-004"
    case updateRejected = "HW-COMPOSE-005"
}

public struct ComposeLoss: Codable, Equatable, Sendable {
    public let code: ComposeLossCode
    public let severity: ComposeLossSeverity
    public let path: String
    public let message: String
    public let line: Int?
    public let policyReasonCode: String?

    public init(
        code: ComposeLossCode,
        severity: ComposeLossSeverity,
        path: String,
        message: String,
        line: Int? = nil,
        policyReasonCode: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.path = path
        self.message = message
        self.line = line
        self.policyReasonCode = policyReasonCode
    }
}

public struct ComposeLossReport: Codable, Equatable, Sendable {
    public let operation: ComposeOperation
    public let losses: [ComposeLoss]

    public init(operation: ComposeOperation, losses: [ComposeLoss]) {
        self.operation = operation
        self.losses = losses.sorted(by: ComposeLossReport.isOrdered)
    }

    public var warnings: [ComposeLoss] {
        losses.filter { $0.severity == .warning }
    }

    public var errors: [ComposeLoss] {
        losses.filter { $0.severity == .error }
    }

    public var canProceed: Bool {
        errors.isEmpty
    }

    private static func isOrdered(_ lhs: ComposeLoss, _ rhs: ComposeLoss) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if (lhs.line ?? Int.max) != (rhs.line ?? Int.max) {
            return (lhs.line ?? Int.max) < (rhs.line ?? Int.max)
        }
        if lhs.severity != rhs.severity {
            return lhs.severity.rawValue < rhs.severity.rawValue
        }
        if lhs.code != rhs.code { return lhs.code.rawValue < rhs.code.rawValue }
        if lhs.message != rhs.message { return lhs.message < rhs.message }
        return (lhs.policyReasonCode ?? "") < (rhs.policyReasonCode ?? "")
    }
}

public struct ComposeImportResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let contractVersion: String
    public let succeeded: Bool
    public let manifestText: String?
    public let canonicalComposeText: String?
    public let lossReport: ComposeLossReport

    public init(
        schemaVersion: Int = ComposeContractVersion.schemaVersion,
        contractVersion: String = ComposeContractVersion.value,
        succeeded: Bool,
        manifestText: String?,
        canonicalComposeText: String?,
        lossReport: ComposeLossReport
    ) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.succeeded = succeeded
        self.manifestText = manifestText
        self.canonicalComposeText = canonicalComposeText
        self.lossReport = lossReport
    }

    public var losses: [ComposeLoss] {
        lossReport.losses
    }

    public var warnings: [ComposeLoss] {
        lossReport.warnings
    }

    public var errors: [ComposeLoss] {
        lossReport.errors
    }
}

public struct ComposeExportResult: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let contractVersion: String
    public let succeeded: Bool
    public let composeText: String?
    public let lossReport: ComposeLossReport

    public init(
        schemaVersion: Int = ComposeContractVersion.schemaVersion,
        contractVersion: String = ComposeContractVersion.value,
        succeeded: Bool,
        composeText: String?,
        lossReport: ComposeLossReport
    ) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.succeeded = succeeded
        self.composeText = composeText
        self.lossReport = lossReport
    }

    public var canonicalComposeText: String? {
        composeText
    }

    public var losses: [ComposeLoss] {
        lossReport.losses
    }

    public var warnings: [ComposeLoss] {
        lossReport.warnings
    }

    public var errors: [ComposeLoss] {
        lossReport.errors
    }
}

public enum ComposeUpdateChangeKind: String, Codable, Equatable, Sendable {
    case addService = "add-service"
    case removeService = "remove-service"
    case updateService = "update-service"
}

public struct ComposeUpdateChange: Codable, Equatable, Sendable {
    public let kind: ComposeUpdateChangeKind
    public let serviceName: String
    public let fields: [String]

    public init(kind: ComposeUpdateChangeKind, serviceName: String, fields: [String]) {
        self.kind = kind
        self.serviceName = serviceName
        self.fields = fields.sorted()
    }
}

public struct ComposeUpdatePlan: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let contractVersion: String
    public let accepted: Bool
    public let changes: [ComposeUpdateChange]
    public let lossReport: ComposeLossReport

    public init(
        schemaVersion: Int = ComposeContractVersion.schemaVersion,
        contractVersion: String = ComposeContractVersion.value,
        accepted: Bool,
        changes: [ComposeUpdateChange],
        lossReport: ComposeLossReport
    ) {
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
        self.accepted = accepted
        self.changes = changes.sorted {
            if $0.serviceName != $1.serviceName { return $0.serviceName < $1.serviceName }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        self.lossReport = lossReport
    }

    public var mutatesRuntime: Bool {
        false
    }

    public var succeeded: Bool {
        accepted
    }

    public var losses: [ComposeLoss] {
        lossReport.losses
    }
}

public enum ComposeContractJSONError: Error, Equatable, Sendable {
    case invalidUTF8
}

public enum ComposeContractJSON {
    public static func render<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComposeContractJSONError.invalidUTF8
        }
        return text
    }
}

public enum HostwrightCompose {
    public static func importDocument(_ text: String) -> ComposeImportResult {
        let imported = StackFileImporter.convert(text)
        let importLosses = imported.diagnostics.map {
            ComposeLoss(
                code: importLossCode(for: $0),
                severity: $0.severity == .warning ? .warning : .error,
                path: diagnosticPath($0, source: text),
                message: $0.message,
                line: $0.line,
                policyReasonCode: $0.policyReasonCode
            )
        }

        guard imported.succeeded, let manifest = imported.manifest, let manifestText = imported.manifestText else {
            return ComposeImportResult(
                succeeded: false,
                manifestText: nil,
                canonicalComposeText: nil,
                lossReport: ComposeLossReport(operation: .importing, losses: importLosses)
            )
        }

        let exported = exportDocument(manifest)
        let losses = importLosses + exported.lossReport.losses
        let report = ComposeLossReport(operation: .importing, losses: losses)
        guard exported.succeeded else {
            return ComposeImportResult(
                succeeded: false,
                manifestText: nil,
                canonicalComposeText: nil,
                lossReport: report
            )
        }

        return ComposeImportResult(
            succeeded: report.canProceed,
            manifestText: report.canProceed ? manifestText : nil,
            canonicalComposeText: report.canProceed ? exported.composeText : nil,
            lossReport: report
        )
    }

    public static func exportDocument(_ manifest: HostwrightManifest) -> ComposeExportResult {
        let losses = manifestValidationLosses(manifest) + representabilityLosses(manifest)
        let report = ComposeLossReport(operation: .exporting, losses: losses)
        guard report.canProceed else {
            return ComposeExportResult(
                succeeded: false,
                composeText: nil,
                lossReport: report
            )
        }

        return ComposeExportResult(
            succeeded: true,
            composeText: renderCanonicalCompose(manifest),
            lossReport: report
        )
    }

    public static func planUpdate(
        current: HostwrightManifest,
        desired: HostwrightManifest
    ) -> ComposeUpdatePlan {
        var losses = manifestValidationLosses(current, prefix: "current")
        losses.append(contentsOf: representabilityLosses(current, prefix: "current"))
        losses.append(contentsOf: manifestValidationLosses(desired, prefix: "desired"))
        losses.append(contentsOf: representabilityLosses(desired, prefix: "desired"))

        if current.project != desired.project {
            losses.append(
                ComposeLoss(
                    code: .updateRejected,
                    severity: .error,
                    path: "$.project",
                    message: "Compose update planning requires the current and desired project names to match."
                )
            )
        }

        let report = ComposeLossReport(operation: .updatePlanning, losses: losses)
        guard report.canProceed else {
            return ComposeUpdatePlan(
                accepted: false,
                changes: [],
                lossReport: report
            )
        }

        let currentServices = Dictionary(uniqueKeysWithValues: current.services.map { ($0.name, $0) })
        let desiredServices = Dictionary(uniqueKeysWithValues: desired.services.map { ($0.name, $0) })
        let serviceNames = Set(currentServices.keys).union(desiredServices.keys).sorted()
        let changes = serviceNames.compactMap { name -> ComposeUpdateChange? in
            switch (currentServices[name], desiredServices[name]) {
            case (.none, .some):
                return ComposeUpdateChange(kind: .addService, serviceName: name, fields: ["service"])
            case (.some, .none):
                return ComposeUpdateChange(kind: .removeService, serviceName: name, fields: ["service"])
            case let (.some(current), .some(desired)):
                let fields = changedFields(current: current, desired: desired)
                guard !fields.isEmpty else { return nil }
                return ComposeUpdateChange(kind: .updateService, serviceName: name, fields: fields)
            case (.none, .none):
                return nil
            }
        }

        return ComposeUpdatePlan(
            accepted: true,
            changes: changes,
            lossReport: report
        )
    }

    private static func importLossCode(for diagnostic: StackImportDiagnostic) -> ComposeLossCode {
        let message = diagnostic.message.lowercased()
        if message.contains("unsupported yaml feature") ||
            message.contains("tab indentation") ||
            message.contains("only 2-space indentation") ||
            message.contains("unterminated quoted scalar") ||
            message.contains("unsupported escape sequence") ||
            message.contains("must separate values") ||
            message.contains("trailing comma") ||
            message.contains("must use inline array syntax") {
            return .invalidInput
        }
        switch diagnostic.code {
        case .manifestParseFailed:
            return .invalidInput
        case .manifestValidationFailed:
            return .invalidManifest
        default:
            return .unsupportedInput
        }
    }

    private static func diagnosticPath(
        _ diagnostic: StackImportDiagnostic,
        source: String
    ) -> String {
        if let path = diagnostic.path {
            return path
        }
        if let service = serviceName(from: diagnostic.message) {
            return "$.services.\(service)"
        }
        guard let lineNumber = diagnostic.line else { return "$.document" }
        let lines = source.components(separatedBy: .newlines)
        guard lines.indices.contains(lineNumber - 1) else { return "$.lines[\(lineNumber)]" }

        var topLevel: String?
        var service: String?
        for line in lines.prefix(lineNumber) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count
            let field = yamlFieldName(trimmed)
            guard !field.isEmpty else { continue }
            if indent == 0 {
                topLevel = field
                service = nil
            } else if topLevel == "services", indent == 2, trimmed.hasSuffix(":") {
                service = field
            }
        }

        let target = lines[lineNumber - 1]
        let indent = target.prefix { $0 == " " }.count
        let field = yamlFieldName(target.trimmingCharacters(in: .whitespaces))
        if topLevel == "services", let service {
            if indent >= 4, !field.isEmpty {
                return "$.services.\(service).\(field)"
            }
            return "$.services.\(service)"
        }
        if let topLevel, !field.isEmpty {
            return "$.\(topLevel).\(field)"
        }
        return "$.lines[\(lineNumber)]"
    }

    private static func serviceName(from message: String) -> String? {
        guard message.hasPrefix("Service '"),
              let end = message.dropFirst("Service '".count).firstIndex(of: "'") else {
            return nil
        }
        let name = String(message[message.index(message.startIndex, offsetBy: "Service '".count)..<end])
        return name.isEmpty ? nil : name
    }

    private static func yamlFieldName(_ trimmed: String) -> String {
        var value = trimmed
        if value.hasPrefix("- ") {
            value = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        guard let colon = value.firstIndex(of: ":") else {
            return value.hasSuffix(":") ? String(value.dropLast()) : ""
        }
        return String(value[..<colon]).trimmingCharacters(in: .whitespaces)
    }

    private static func manifestValidationLosses(
        _ manifest: HostwrightManifest,
        prefix: String? = nil
    ) -> [ComposeLoss] {
        ManifestValidator.validate(manifest).map { issue in
            let path: String
            if let issuePath = issue.path {
                if let prefix {
                    path = issuePath.hasPrefix("$.")
                        ? "$.\(prefix)\(issuePath.dropFirst())"
                        : "$.\(prefix).\(issuePath)"
                } else {
                    path = issuePath
                }
            } else {
                path = prefix.map { "$.\($0).manifest" } ?? "$.manifest"
            }
            return ComposeLoss(
                code: .invalidManifest,
                severity: .error,
                path: path,
                message: issue.message,
                line: issue.line
            )
        }
    }

    private static func representabilityLosses(
        _ manifest: HostwrightManifest,
        prefix: String? = nil
    ) -> [ComposeLoss] {
        var losses: [ComposeLoss] = []
        let root = prefix.map { "$.\($0)" } ?? "$"
        func add(_ path: String, _ message: String) {
            losses.append(
                ComposeLoss(
                    code: .exportLoss,
                    severity: .error,
                    path: path,
                    message: message
                )
            )
        }

        if manifest.imagePolicy == .requireDigest {
            add(
                "\(root).imagePolicy",
                "Compose export cannot preserve Hostwright imagePolicy require-digest semantics."
            )
        }
        if manifest.imageTrust != nil {
            add("\(root).imageTrust", "Compose export cannot preserve Hostwright image trust policy semantics.")
        }
        if manifest.imageSBOM != nil {
            add("\(root).imageSBOM", "Compose export cannot preserve Hostwright image SBOM policy semantics.")
        }
        if manifest.imageVulnerability != nil {
            add("\(root).imageVulnerability", "Compose export cannot preserve Hostwright vulnerability policy semantics.")
        }
        if manifest.imageProvenance != nil {
            add("\(root).imageProvenance", "Compose export cannot preserve Hostwright image provenance policy semantics.")
        }
        if manifest.restartBudget != nil {
            add("\(root).restartBudget", "Compose export cannot preserve Hostwright project restart budget semantics.")
        }
        if manifest.maintenance != nil {
            add("\(root).maintenance", "Compose export cannot preserve Hostwright maintenance policy semantics.")
        }
        if manifest.retention != nil {
            add("\(root).retention", "Compose export cannot preserve Hostwright retention policy semantics.")
        }
        if !manifest.volumes.isEmpty {
            add("\(root).volumes", "Compose export cannot preserve Hostwright top-level volume declarations in this contract.")
        }
        if !manifest.networks.isEmpty {
            add("\(root).networks", "Compose export cannot preserve Hostwright top-level network declarations in this contract.")
        }
        if !manifest.certificates.isEmpty {
            add("\(root).certificates", "Compose export cannot preserve Hostwright certificate declarations.")
        }
        if !manifest.ingress.isEmpty {
            add("\(root).ingress", "Compose export cannot preserve Hostwright ingress declarations.")
        }
        if !manifest.tunnels.isEmpty {
            add("\(root).tunnels", "Compose export cannot preserve Hostwright tunnel declarations.")
        }

        for service in manifest.services {
            let serviceRoot = "\(root).services.\(service.name)"
            if service.replicas != 1 {
                add("\(serviceRoot).replicas", "Compose export cannot preserve Hostwright replica semantics in this contract.")
            }
            if service.platform != HostwrightPlatform() {
                add("\(serviceRoot).platform", "Compose export cannot preserve Hostwright platform semantics in this contract.")
            }
            if service.resources != nil {
                add("\(serviceRoot).resources", "Compose export cannot preserve Hostwright resource semantics in this contract.")
            }
            if service.user != nil {
                add("\(serviceRoot).user", "Compose export cannot preserve Hostwright user semantics in this contract.")
            }
            if service.group != nil {
                add("\(serviceRoot).group", "Compose export cannot preserve Hostwright group semantics in this contract.")
            }
            if service.workdir != nil {
                add("\(serviceRoot).workdir", "Compose export cannot preserve Hostwright workdir semantics in this contract.")
            }
            if !service.entrypoint.isEmpty {
                add("\(serviceRoot).entrypoint", "Compose export cannot preserve entrypoint semantics in the canonical import subset.")
            }
            if service.initProcess {
                add("\(serviceRoot).initProcess", "Compose export cannot preserve Hostwright initProcess semantics.")
            }
            if !service.dependsOn.isEmpty {
                add("\(serviceRoot).dependsOn", "Compose export cannot preserve dependency conditions in the canonical import subset.")
            }
            if !service.secretEnv.isEmpty {
                add("\(serviceRoot).secretEnv", "Compose export cannot preserve secret environment references.")
            }
            if !service.labels.isEmpty {
                add("\(serviceRoot).labels", "Compose export cannot preserve labels in the canonical import subset.")
            }
            if !service.publishedSockets.isEmpty {
                add("\(serviceRoot).publishedSockets", "Compose export cannot preserve Unix socket publications.")
            }
            if !service.hostAccess.isEmpty {
                add("\(serviceRoot).hostAccess", "Compose export cannot preserve guarded host access semantics.")
            }
            if !service.networks.isEmpty {
                add("\(serviceRoot).networks", "Compose export cannot preserve service network attachments.")
            }
            if service.networkPolicy != nil {
                add("\(serviceRoot).networkPolicy", "Compose export cannot preserve service network policy semantics.")
            }
            if service.probes.startup != nil || service.probes.readiness != nil || !legacyHealthProbeMatches(service) {
                add("\(serviceRoot).probes", "Compose export cannot preserve Hostwright probe semantics.")
            }
            if service.update != HostwrightUpdatePolicy() {
                add("\(serviceRoot).update", "Compose export cannot preserve Hostwright update policy semantics.")
            }
            if service.hooks != HostwrightHooks() {
                add("\(serviceRoot).hooks", "Compose export cannot preserve Hostwright lifecycle hook semantics.")
            }
            if service.rosetta {
                add("\(serviceRoot).rosetta", "Compose export cannot preserve Rosetta execution semantics.")
            }
            if service.virtualization {
                add("\(serviceRoot).virtualization", "Compose export cannot preserve virtualization semantics.")
            }
            if service.readOnlyRootFilesystem {
                add("\(serviceRoot).readOnlyRootFilesystem", "Compose export cannot preserve read-only root filesystem semantics.")
            }
            if service.shmSize != nil {
                add("\(serviceRoot).shmSize", "Compose export cannot preserve shared-memory sizing semantics.")
            }

            if service.publishedPorts.contains(where: { $0.legacyLiteral == nil }) {
                add("\(serviceRoot).publishedPorts", "Compose export cannot preserve structured port publication semantics in the canonical import subset.")
            }
            if !service.publishedPorts.isEmpty,
               service.ports != service.publishedPorts.compactMap(\.canonicalLegacyLiteral) {
                add("\(serviceRoot).ports", "Compose export cannot preserve divergent legacy and structured port declarations.")
            }
            if service.publishedPorts.isEmpty,
               service.ports.contains(where: { HostwrightPublishedPort.legacy($0) == nil }) {
                add("\(serviceRoot).ports", "Compose export requires legacy host:container port strings in the canonical import subset.")
            }
            for (index, volume) in service.volumes.enumerated() {
                if !isExplicitHostPathVolume(volume) {
                    add("\(serviceRoot).volumes[\(index)]", "Compose export cannot preserve named or non-host-path volume semantics in the canonical import subset.")
                }
            }
            let expectedMounts = service.volumes.compactMap(HostwrightMountSpec.legacy)
            if !service.mounts.isEmpty, service.mounts != expectedMounts {
                add("\(serviceRoot).mounts", "Compose export cannot preserve structured mount semantics in the canonical import subset.")
            }
        }
        return losses
    }

    private static func isExplicitHostPathVolume(_ volume: String) -> Bool {
        let parts = volume.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return false }
        let source = String(parts[0])
        return source.hasPrefix("./") || source.hasPrefix("/")
    }

    private static func legacyHealthProbeMatches(_ service: HostwrightService) -> Bool {
        guard let liveness = service.probes.liveness else { return true }
        guard let health = service.health else { return false }
        guard liveness.startPeriod == 0,
              liveness.timeout == 3,
              liveness.successThreshold == 1,
              liveness.failureThreshold == 3,
              case .exec(let command) = liveness.action,
              command == health.command else {
            return false
        }

        let expectedInterval: Int
        if let interval = health.interval,
           interval.hasSuffix("s"),
           let seconds = Int(interval.dropLast()) {
            expectedInterval = seconds
        } else {
            expectedInterval = 10
        }
        return liveness.interval == expectedInterval
    }

    private static func renderCanonicalCompose(_ manifest: HostwrightManifest) -> String {
        var lines: [String] = []
        if let project = manifest.project {
            lines.append("name: \(quoted(project))")
        }
        lines.append("services:")

        for service in manifest.services.sorted(by: { $0.name < $1.name }) {
            lines.append("  \(service.name):")
            if let image = service.image {
                lines.append("    image: \(quoted(image))")
            }
            if !service.command.isEmpty {
                lines.append("    command: \(inlineArray(service.command))")
            }

            let ports = composePorts(for: service).sorted()
            if !ports.isEmpty {
                lines.append("    ports:")
                ports.forEach { lines.append("      - \(quoted($0))") }
            }

            let volumes = service.volumes.sorted()
            if !volumes.isEmpty {
                lines.append("    volumes:")
                volumes.forEach { lines.append("      - \(quoted($0))") }
            }

            if !service.env.isEmpty {
                lines.append("    environment:")
                for key in service.env.keys.sorted() {
                    lines.append("      \(key): \(quoted(service.env[key] ?? ""))")
                }
            }

            if let health = service.health {
                lines.append("    healthcheck:")
                lines.append("      test: \(inlineArray(["CMD"] + health.command))")
                if let interval = health.interval {
                    lines.append("      interval: \(quoted(interval))")
                }
            }
            if let restart = service.restart {
                lines.append("    restart: \(quoted(restart.policy))")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func composePorts(for service: HostwrightService) -> [String] {
        if !service.publishedPorts.isEmpty {
            return service.publishedPorts.compactMap(\.legacyLiteral)
        }
        return service.ports
    }

    private static func changedFields(
        current: HostwrightService,
        desired: HostwrightService
    ) -> [String] {
        var fields: [String] = []
        if current.image != desired.image { fields.append("image") }
        if current.command != desired.command { fields.append("command") }
        if current.env != desired.env { fields.append("env") }
        if composePorts(for: current).sorted() != composePorts(for: desired).sorted() { fields.append("ports") }
        if current.volumes.sorted() != desired.volumes.sorted() { fields.append("volumes") }
        if current.health != desired.health { fields.append("healthcheck") }
        if current.restart != desired.restart { fields.append("restart") }
        return fields.sorted()
    }

    private static func inlineArray(_ values: [String]) -> String {
        "[" + values.map(quoted).joined(separator: ", ") + "]"
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }
}
