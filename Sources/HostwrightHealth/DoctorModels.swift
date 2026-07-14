import HostwrightCore

public enum DoctorCheckIdentifier: String, Equatable, Sendable {
    case operatingSystem
    case appleSilicon
    case macOSVersion
    case swiftToolchain
    case appleContainerCLI
    case manifestPresence
    case statePathPolicy
    case telemetryPolicy
    case resourceIntelligence
}

public enum DoctorCheckStatus: String, Equatable, Sendable {
    case pass
    case warning
    case fail
}

public struct DoctorCheck: Equatable, Sendable {
    public let identifier: DoctorCheckIdentifier
    public let status: DoctorCheckStatus
    public let message: String

    public init(identifier: DoctorCheckIdentifier, status: DoctorCheckStatus, message: String) {
        self.identifier = identifier
        self.status = status
        self.message = message
    }
}

public struct DoctorReport: Equatable, Sendable {
    public let checks: [DoctorCheck]
    public let resourceReport: ResourceIntelligenceReport?

    public init(checks: [DoctorCheck], resourceReport: ResourceIntelligenceReport? = nil) {
        self.checks = checks
        self.resourceReport = resourceReport
    }

    public var hasFailures: Bool {
        checks.contains { $0.status == .fail }
    }
}

public enum DoctorScaffold {
    public static func compatibilityChecks(for snapshot: PlatformSnapshot) -> [DoctorCheck] {
        CompatibilityGate.evaluate(snapshot).map { diagnostic in
            DoctorCheck(identifier: diagnostic.code == .unsupportedArchitecture ? .appleSilicon : .macOSVersion, status: .fail, message: diagnostic.message)
        }
    }
}

public struct DoctorInputs: Equatable, Sendable {
    public let operatingSystemDescription: String
    public let platform: PlatformSnapshot
    public let swiftVersion: String?
    public let containerExecutablePath: String?
    public let manifestExists: Bool
    public let resourceSnapshot: ResourceIntelligenceSnapshot?
    public let localPathResolution: HostwrightLocalPathResolution?
    public let localPathReadiness: HostwrightLocalPathReadiness?
    public let localPathPolicyError: String?

    public init(
        operatingSystemDescription: String,
        platform: PlatformSnapshot,
        swiftVersion: String?,
        containerExecutablePath: String?,
        manifestExists: Bool,
        resourceSnapshot: ResourceIntelligenceSnapshot? = nil,
        localPathResolution: HostwrightLocalPathResolution? = nil,
        localPathReadiness: HostwrightLocalPathReadiness? = nil,
        localPathPolicyError: String? = nil
    ) {
        self.operatingSystemDescription = operatingSystemDescription
        self.platform = platform
        self.swiftVersion = swiftVersion
        self.containerExecutablePath = containerExecutablePath
        self.manifestExists = manifestExists
        self.resourceSnapshot = resourceSnapshot
        self.localPathResolution = localPathResolution
        self.localPathReadiness = localPathReadiness
        self.localPathPolicyError = localPathPolicyError
    }
}

public enum HostwrightDoctor {
    public static func report(inputs: DoctorInputs) -> DoctorReport {
        var checks: [DoctorCheck] = [
            DoctorCheck(identifier: .operatingSystem, status: .pass, message: inputs.operatingSystemDescription)
        ]

        let compatibilityDiagnostics = CompatibilityGate.evaluate(inputs.platform)
        if compatibilityDiagnostics.isEmpty {
            checks.append(DoctorCheck(identifier: .appleSilicon, status: .pass, message: "Architecture is \(inputs.platform.architecture)."))
            checks.append(DoctorCheck(identifier: .macOSVersion, status: .pass, message: "macOS major version is \(inputs.platform.macOSMajorVersion)."))
        } else {
            checks.append(contentsOf: DoctorScaffold.compatibilityChecks(for: inputs.platform))
        }

        if let swiftVersion = inputs.swiftVersion, !swiftVersion.isEmpty {
            checks.append(DoctorCheck(identifier: .swiftToolchain, status: .pass, message: swiftVersion))
        } else {
            checks.append(DoctorCheck(identifier: .swiftToolchain, status: .warning, message: "Swift toolchain version was not available."))
        }

        if let containerExecutablePath = inputs.containerExecutablePath {
            checks.append(DoctorCheck(identifier: .appleContainerCLI, status: .pass, message: "Found container CLI at \(containerExecutablePath)."))
        } else {
            checks.append(DoctorCheck(identifier: .appleContainerCLI, status: .warning, message: "Apple container CLI was not found on PATH. Runtime checks are unavailable."))
        }

        checks.append(
            DoctorCheck(
                identifier: .manifestPresence,
                status: inputs.manifestExists ? .pass : .warning,
                message: inputs.manifestExists ? "Found hostwright.yaml in the current directory." : "No hostwright.yaml found in the current directory."
            )
        )
        if let resolution = inputs.localPathResolution {
            let readiness = inputs.localPathReadiness
            let status: DoctorCheckStatus
            switch readiness {
            case .blockedConflict, .blockedPolicy, .none:
                status = .fail
            case .migrationRequired:
                status = .warning
            case .ready, .needsCreation:
                status = .pass
            }
            let readinessText = readiness?.rawValue ?? "unknown"
            let policyText = inputs.localPathPolicyError.map { "; policyError=\($0)" } ?? ""
            checks.append(
                DoctorCheck(
                    identifier: .statePathPolicy,
                    status: status,
                    message: "State origin=\(resolution.statePathOrigin.rawValue); readiness=\(readinessText); path=\(resolution.stateDatabasePath); owned directories require 0700 and sensitive files require 0600\(policyText)."
                )
            )
        } else {
            let hasResolutionError = inputs.localPathPolicyError != nil
            checks.append(
                DoctorCheck(
                    identifier: .statePathPolicy,
                    status: hasResolutionError ? .fail : .warning,
                    message: inputs.localPathPolicyError
                        .map { "The secure local path contract could not be resolved: \($0)." }
                        ?? "Secure local path inputs were not supplied to this doctor invocation."
                )
            )
        }
        checks.append(DoctorCheck(identifier: .telemetryPolicy, status: .pass, message: "Telemetry is local-only. Hostwright does not upload diagnostics or events."))

        let resourceReport = inputs.resourceSnapshot.map(ResourceIntelligenceReport.init(snapshot:))
        if let resourceReport {
            checks.append(
                DoctorCheck(
                    identifier: .resourceIntelligence,
                    status: resourceReport.hasThermalWarning ? .warning : .pass,
                    message: resourceIntelligenceMessage(for: resourceReport)
                )
            )
        } else {
            checks.append(
                DoctorCheck(
                    identifier: .resourceIntelligence,
                    status: .warning,
                    message: "Resource intelligence snapshot was not available; doctor did not infer capacity."
                )
            )
        }

        return DoctorReport(checks: checks, resourceReport: resourceReport)
    }

    private static func resourceIntelligenceMessage(for report: ResourceIntelligenceReport) -> String {
        let memoryText = report.hardware.physicalMemoryBytes.map(String.init) ?? "unknown"
        let appleContainerVersion = report.appleContainer.version ?? "unavailable"
        return "Resource report method \(report.measurementMethod.rawValue); physicalMemoryBytes=\(memoryText); Apple container version=\(appleContainerVersion); no capacity guarantee."
    }
}
