import Foundation
import HostwrightCore

public enum DoctorCheckIdentifier: String, Codable, Equatable, Sendable {
    case operatingSystem
    case appleSilicon
    case macOSVersion
    case appleContainerCLI
    case appleContainerService
    case manifestPresence
    case statePathPolicy
    case stateIntegrity
    case statePermissions
    case localNetwork
    case signingTrust
    case resourcePressure
    case requiredTools
    case telemetryPolicy
    case resourceIntelligence
}

public enum DoctorReadinessState: String, CaseIterable, Codable, Equatable, Sendable {
    case ready
    case degraded
    case blocked
    case unsupported
    case externallyConstrained = "externally-constrained"

    fileprivate var precedence: Int {
        switch self {
        case .ready:
            return 0
        case .degraded:
            return 1
        case .externallyConstrained:
            return 2
        case .blocked:
            return 3
        case .unsupported:
            return 4
        }
    }
}

public typealias DoctorCheckStatus = DoctorReadinessState

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let identifier: DoctorCheckIdentifier
    public let status: DoctorReadinessState
    public let message: String
    public let remediation: String?
    public let details: [String: String]

    public init(
        identifier: DoctorCheckIdentifier,
        status: DoctorReadinessState,
        message: String,
        remediation: String? = nil,
        details: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.status = status
        self.message = message
        self.remediation = remediation
        self.details = details
    }
}

public struct DoctorReport: Equatable, Sendable {
    public let schemaVersion: Int
    public let checks: [DoctorCheck]
    public let resourceReport: ResourceIntelligenceReport?

    public init(
        schemaVersion: Int = 2,
        checks: [DoctorCheck],
        resourceReport: ResourceIntelligenceReport? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.checks = checks
        self.resourceReport = resourceReport
    }

    public var readiness: DoctorReadinessState {
        checks.map(\.status).max { $0.precedence < $1.precedence } ?? .ready
    }

    public var hasFailures: Bool {
        checks.contains { $0.status == .blocked || $0.status == .unsupported }
    }

    public var hasExternalConstraints: Bool {
        checks.contains { $0.status == .externallyConstrained }
    }
}

public enum DoctorRuntimeAvailability: String, Codable, Equatable, Sendable {
    case ready
    case cliMissing = "cli-missing"
    case serviceNotRunning = "service-not-running"
    case serviceUnregistered = "service-unregistered"
    case permissionDenied = "permission-denied"
    case probeFailed = "probe-failed"
}

public struct DoctorRuntimeSnapshot: Codable, Equatable, Sendable {
    public let availability: DoctorRuntimeAvailability
    public let cliVersion: String?
    public let serviceVersion: String?
    public let serviceBuild: String?
    public let diagnostic: String?

    public init(
        availability: DoctorRuntimeAvailability,
        cliVersion: String? = nil,
        serviceVersion: String? = nil,
        serviceBuild: String? = nil,
        diagnostic: String? = nil
    ) {
        self.availability = availability
        self.cliVersion = cliVersion
        self.serviceVersion = serviceVersion
        self.serviceBuild = serviceBuild
        self.diagnostic = diagnostic
    }
}

public enum DoctorStateAvailability: String, Codable, Equatable, Sendable {
    case absent
    case healthy
    case degraded
    case unrecoverable
    case inspectionFailed = "inspection-failed"
}

public struct DoctorStateSnapshot: Codable, Equatable, Sendable {
    public let availability: DoctorStateAvailability
    public let stateSchemaVersion: Int?
    public let databaseSHA256: String?
    public let diagnostic: String?
    public let recommendedAction: String?

    public init(
        availability: DoctorStateAvailability,
        stateSchemaVersion: Int? = nil,
        databaseSHA256: String? = nil,
        diagnostic: String? = nil,
        recommendedAction: String? = nil
    ) {
        self.availability = availability
        self.stateSchemaVersion = stateSchemaVersion
        self.databaseSHA256 = databaseSHA256
        self.diagnostic = diagnostic
        self.recommendedAction = recommendedAction
    }
}

public enum DoctorScaffold {
    public static func compatibilityChecks(for snapshot: PlatformSnapshot) -> [DoctorCheck] {
        CompatibilityGate.evaluate(snapshot).map { diagnostic in
            let identifier: DoctorCheckIdentifier = diagnostic.code == .unsupportedArchitecture
                ? .appleSilicon
                : .macOSVersion
            return DoctorCheck(
                identifier: identifier,
                status: .unsupported,
                message: diagnostic.message,
                remediation: identifier == .appleSilicon
                    ? "Run Hostwright on a supported Apple-silicon Mac."
                    : "Upgrade to a supported macOS release before running Hostwright."
            )
        }
    }
}

public struct DoctorInputs: Equatable, Sendable {
    public let operatingSystemDescription: String
    public let platform: PlatformSnapshot
    public let containerExecutablePath: String?
    public let manifestExists: Bool
    public let runtimeSnapshot: DoctorRuntimeSnapshot
    public let stateSnapshot: DoctorStateSnapshot
    public let systemSnapshot: DoctorSystemSnapshot
    public let resourceSnapshot: ResourceIntelligenceSnapshot?
    public let localPathResolution: HostwrightLocalPathResolution?
    public let localPathReadiness: HostwrightLocalPathReadiness?
    public let localPathPolicyError: String?

    public init(
        operatingSystemDescription: String,
        platform: PlatformSnapshot,
        containerExecutablePath: String?,
        manifestExists: Bool,
        runtimeSnapshot: DoctorRuntimeSnapshot? = nil,
        stateSnapshot: DoctorStateSnapshot = DoctorStateSnapshot(availability: .absent),
        systemSnapshot: DoctorSystemSnapshot = .unavailable(),
        resourceSnapshot: ResourceIntelligenceSnapshot? = nil,
        localPathResolution: HostwrightLocalPathResolution? = nil,
        localPathReadiness: HostwrightLocalPathReadiness? = nil,
        localPathPolicyError: String? = nil
    ) {
        self.operatingSystemDescription = operatingSystemDescription
        self.platform = platform
        self.containerExecutablePath = containerExecutablePath
        self.manifestExists = manifestExists
        self.runtimeSnapshot = runtimeSnapshot ?? DoctorRuntimeSnapshot(
            availability: containerExecutablePath == nil ? .cliMissing : .probeFailed,
            diagnostic: containerExecutablePath == nil
                ? "Apple container CLI was not found."
                : "Apple container service readiness was not probed."
        )
        self.stateSnapshot = stateSnapshot
        self.systemSnapshot = systemSnapshot
        self.resourceSnapshot = resourceSnapshot
        self.localPathResolution = localPathResolution
        self.localPathReadiness = localPathReadiness
        self.localPathPolicyError = localPathPolicyError
    }
}

public enum HostwrightDoctor {
    public static func report(inputs: DoctorInputs) -> DoctorReport {
        var checks = [
            DoctorCheck(
                identifier: .operatingSystem,
                status: .ready,
                message: inputs.operatingSystemDescription,
                details: ["description": inputs.operatingSystemDescription]
            )
        ]

        let compatibility = DoctorScaffold.compatibilityChecks(for: inputs.platform)
        if compatibility.isEmpty {
            checks.append(
                DoctorCheck(
                    identifier: .appleSilicon,
                    status: .ready,
                    message: "The host architecture is supported.",
                    details: ["architecture": inputs.platform.architecture]
                )
            )
            checks.append(
                DoctorCheck(
                    identifier: .macOSVersion,
                    status: .ready,
                    message: "The macOS major version is supported.",
                    details: ["majorVersion": String(inputs.platform.macOSMajorVersion)]
                )
            )
        } else {
            checks.append(contentsOf: compatibility)
        }

        checks.append(runtimeCLICheck(inputs))
        checks.append(runtimeServiceCheck(inputs.runtimeSnapshot))
        checks.append(
            DoctorCheck(
                identifier: .manifestPresence,
                status: inputs.manifestExists ? .ready : .degraded,
                message: inputs.manifestExists
                    ? "The project manifest is present."
                    : "No project manifest was found in the current directory.",
                remediation: inputs.manifestExists
                    ? nil
                    : "Run hostwright init or execute project commands with an explicit manifest path."
            )
        )
        checks.append(statePathCheck(inputs))
        checks.append(stateIntegrityCheck(inputs.stateSnapshot))
        checks.append(statePermissionsCheck(inputs))
        checks.append(localNetworkCheck(inputs.systemSnapshot.localNetwork))
        checks.append(signingTrustCheck(inputs.systemSnapshot.signingTrust))
        checks.append(resourcePressureCheck(inputs.systemSnapshot.resourcePressure))
        checks.append(requiredToolsCheck(inputs.systemSnapshot.tools))
        checks.append(
            DoctorCheck(
                identifier: .telemetryPolicy,
                status: .ready,
                message: "Diagnostics remain local and no telemetry is uploaded."
            )
        )

        let resourceReport = inputs.resourceSnapshot.map(ResourceIntelligenceReport.init(snapshot:))
        if let resourceReport {
            checks.append(
                DoctorCheck(
                    identifier: .resourceIntelligence,
                    status: resourceReport.hasThermalWarning ? .degraded : .ready,
                    message: resourceIntelligenceMessage(for: resourceReport),
                    remediation: resourceReport.hasThermalWarning
                        ? "Reduce workload pressure and wait for the host thermal state to recover."
                        : nil
                )
            )
        } else {
            checks.append(
                DoctorCheck(
                    identifier: .resourceIntelligence,
                    status: .degraded,
                    message: "The extended resource-intelligence snapshot was unavailable.",
                    remediation: "Run doctor again after host resource probes become available."
                )
            )
        }

        return DoctorReport(checks: checks, resourceReport: resourceReport)
    }

    private static func runtimeCLICheck(_ inputs: DoctorInputs) -> DoctorCheck {
        guard inputs.containerExecutablePath != nil else {
            return DoctorCheck(
                identifier: .appleContainerCLI,
                status: .externallyConstrained,
                message: "Apple container CLI is not installed or is not discoverable on PATH.",
                remediation: "Install a supported Apple container release and ensure the container executable is on PATH."
            )
        }
        return DoctorCheck(
            identifier: .appleContainerCLI,
            status: .ready,
            message: "Apple container CLI is available.",
            details: inputs.runtimeSnapshot.cliVersion.map { ["version": $0] } ?? [:]
        )
    }

    private static func runtimeServiceCheck(_ snapshot: DoctorRuntimeSnapshot) -> DoctorCheck {
        let details = [
            "availability": snapshot.availability.rawValue,
            "cliVersion": snapshot.cliVersion,
            "serviceVersion": snapshot.serviceVersion,
            "serviceBuild": snapshot.serviceBuild
        ].compactMapValues { $0 }
        switch snapshot.availability {
        case .ready:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .ready,
                message: "Apple container services are running and responsive.",
                details: details
            )
        case .cliMissing:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .externallyConstrained,
                message: "Apple container service readiness cannot be checked without the CLI.",
                remediation: "Install a supported Apple container release, then run hostwright doctor again.",
                details: details
            )
        case .serviceNotRunning:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .externallyConstrained,
                message: "Apple container services are installed but not running.",
                remediation: "Start Apple container services with container system start, then run hostwright doctor again.",
                details: details
            )
        case .serviceUnregistered:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .externallyConstrained,
                message: "Apple container services are not registered for the current user.",
                remediation: "Install or register Apple container services, then run hostwright doctor again.",
                details: details
            )
        case .permissionDenied:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .blocked,
                message: snapshot.diagnostic ?? "Permission to inspect Apple container services was denied.",
                remediation: "Restore access for the current user without broadening Hostwright privileges.",
                details: details
            )
        case .probeFailed:
            return DoctorCheck(
                identifier: .appleContainerService,
                status: .externallyConstrained,
                message: snapshot.diagnostic ?? "Apple container service readiness could not be established.",
                remediation: "Run container system status, correct the reported service condition, and retry doctor.",
                details: details
            )
        }
    }

    private static func statePathCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        guard let resolution = inputs.localPathResolution else {
            return DoctorCheck(
                identifier: .statePathPolicy,
                status: inputs.localPathPolicyError == nil ? .degraded : .blocked,
                message: inputs.localPathPolicyError
                    ?? "The secure local state path was not resolved.",
                remediation: "Correct the state path or Hostwright path overrides and retry doctor."
            )
        }
        let readiness = inputs.localPathReadiness
        let details = [
            "origin": resolution.statePathOrigin.rawValue,
            "readiness": readiness?.rawValue ?? "unknown"
        ]
        switch readiness {
        case .ready, .needsCreation:
            return DoctorCheck(
                identifier: .statePathPolicy,
                status: .ready,
                message: "The selected state path satisfies the secure path policy.",
                details: details
            )
        case .migrationRequired:
            return DoctorCheck(
                identifier: .statePathPolicy,
                status: .degraded,
                message: "The selected state path requires an explicit migration before mutation.",
                remediation: "Complete the reported state migration and rerun doctor.",
                details: details
            )
        case .blockedConflict:
            return DoctorCheck(
                identifier: .statePathPolicy,
                status: .blocked,
                message: "Both current and legacy state databases exist; Hostwright refuses to choose destructively.",
                remediation: "Verify both databases, preserve a backup, and resolve the conflict explicitly.",
                details: details
            )
        case .blockedPolicy, .none:
            return DoctorCheck(
                identifier: .statePathPolicy,
                status: .blocked,
                message: inputs.localPathPolicyError ?? "The selected state path failed secure policy validation.",
                remediation: "Correct ownership, mode, ACL, symlink, or path-policy violations and retry doctor.",
                details: details
            )
        }
    }

    private static func stateIntegrityCheck(_ snapshot: DoctorStateSnapshot) -> DoctorCheck {
        var details = ["availability": snapshot.availability.rawValue]
        if let stateSchemaVersion = snapshot.stateSchemaVersion {
            details["stateSchemaVersion"] = String(stateSchemaVersion)
        }
        if let databaseSHA256 = snapshot.databaseSHA256 {
            details["databaseSHA256"] = databaseSHA256
        }
        switch snapshot.availability {
        case .absent:
            return DoctorCheck(
                identifier: .stateIntegrity,
                status: .degraded,
                message: "No state database exists yet; integrity has not been established.",
                remediation: "Run a state-creating Hostwright command when the project is ready.",
                details: details
            )
        case .healthy:
            return DoctorCheck(
                identifier: .stateIntegrity,
                status: .ready,
                message: "The existing state database passed immutable integrity inspection.",
                details: details
            )
        case .degraded:
            return DoctorCheck(
                identifier: .stateIntegrity,
                status: .degraded,
                message: snapshot.diagnostic ?? "The existing state database is usable but requires maintenance.",
                remediation: snapshot.recommendedAction,
                details: details
            )
        case .unrecoverable, .inspectionFailed:
            return DoctorCheck(
                identifier: .stateIntegrity,
                status: .blocked,
                message: snapshot.diagnostic ?? "The existing state database failed immutable integrity inspection.",
                remediation: snapshot.recommendedAction
                    ?? "Restore a verified backup or run explicit state recovery before mutation.",
                details: details
            )
        }
    }

    private static func statePermissionsCheck(_ inputs: DoctorInputs) -> DoctorCheck {
        guard inputs.localPathResolution != nil else {
            let blocked = inputs.localPathPolicyError != nil
            return DoctorCheck(
                identifier: .statePermissions,
                status: blocked ? .blocked : .degraded,
                message: blocked
                    ? "State ownership and permission policy could not be established."
                    : "State ownership and permission facts were not supplied.",
                remediation: "Resolve the state path and rerun doctor to verify ownership, modes, ACLs, and file identity."
            )
        }
        let blocked = inputs.localPathPolicyError != nil
            || inputs.localPathReadiness == .blockedPolicy
            || inputs.localPathReadiness == .blockedConflict
        return DoctorCheck(
            identifier: .statePermissions,
            status: blocked ? .blocked : .ready,
            message: blocked
                ? "State ownership, permissions, ACL, or identity checks did not pass."
                : "State path ownership and permission policy checks passed.",
            remediation: blocked
                ? "Use user-owned directories with mode 0700 and sensitive files with mode 0600; remove access-granting ACLs and symlinks."
                : nil
        )
    }

    private static func localNetworkCheck(_ snapshot: DoctorLocalNetworkSnapshot) -> DoctorCheck {
        let details = [
            "loopbackAvailable": String(snapshot.loopbackAvailable),
            "activeNonLoopbackInterfaceCount": String(snapshot.activeNonLoopbackInterfaceCount),
            "hasIPv4": String(snapshot.hasIPv4),
            "hasIPv6": String(snapshot.hasIPv6),
            "authorizationWasProbed": String(snapshot.authorizationWasProbed)
        ]
        if !snapshot.loopbackAvailable {
            return DoctorCheck(
                identifier: .localNetwork,
                status: .blocked,
                message: snapshot.probeError ?? "A usable loopback interface was not observed.",
                remediation: "Restore the macOS loopback interface before running local control or runtime services.",
                details: details
            )
        }
        if snapshot.activeNonLoopbackInterfaceCount == 0 {
            return DoctorCheck(
                identifier: .localNetwork,
                status: .degraded,
                message: snapshot.probeError ?? "Loopback is available, but no active external network interface was observed.",
                remediation: "Connect an interface before workflows that require registries, LAN access, or remote peers.",
                details: details
            )
        }
        return DoctorCheck(
            identifier: .localNetwork,
            status: .ready,
            message: "Loopback and at least one active network interface are available.",
            details: details
        )
    }

    private static func signingTrustCheck(_ snapshot: DoctorSigningTrustSnapshot) -> DoctorCheck {
        let trusted = snapshot.codeSignature == .developerID && snapshot.gatekeeper == .accepted
        let invalid = snapshot.codeSignature == .invalid
        let status: DoctorReadinessState
        if trusted {
            status = .ready
        } else if invalid || !snapshot.developmentBuild {
            status = .blocked
        } else {
            status = .degraded
        }
        return DoctorCheck(
            identifier: .signingTrust,
            status: status,
            message: trusted
                ? "The running executable has a Developer ID signature accepted by Gatekeeper."
                : snapshot.probeError ?? "The running executable is not a Gatekeeper-accepted Developer ID build.",
            remediation: status == .ready
                ? nil
                : snapshot.developmentBuild
                    ? "Use signed and notarized distribution artifacts for production qualification."
                    : "Reinstall Hostwright from a signed and notarized trusted distribution.",
            details: [
                "codeSignature": snapshot.codeSignature.rawValue,
                "gatekeeper": snapshot.gatekeeper.rawValue,
                "developmentBuild": String(snapshot.developmentBuild)
            ]
        )
    }

    private static func resourcePressureCheck(_ snapshot: DoctorResourcePressureSnapshot) -> DoctorCheck {
        let memoryPercent = snapshot.reclaimableMemoryPercent
        let blocked = snapshot.thermalState == .critical || memoryPercent.map { $0 < 5 } == true
        let degraded = snapshot.thermalState == .fair
            || snapshot.thermalState == .serious
            || snapshot.thermalState == .unknown
            || memoryPercent.map { $0 < 20 } == true
            || memoryPercent == nil
        let status: DoctorReadinessState = blocked ? .blocked : degraded ? .degraded : .ready
        var details = [
            "physicalMemoryBytes": String(snapshot.physicalMemoryBytes),
            "thermalState": snapshot.thermalState.rawValue
        ]
        if let reclaimableMemoryBytes = snapshot.reclaimableMemoryBytes {
            details["reclaimableMemoryBytes"] = String(reclaimableMemoryBytes)
        }
        if let memoryPercent {
            details["reclaimableMemoryPercent"] = String(format: "%.2f", memoryPercent)
        }
        return DoctorCheck(
            identifier: .resourcePressure,
            status: status,
            message: snapshot.probeError ?? "Host memory availability and thermal pressure were inspected.",
            remediation: status == .ready
                ? nil
                : "Reduce host workload pressure and wait for memory and thermal conditions to recover.",
            details: details
        )
    }

    private static func requiredToolsCheck(_ tools: [DoctorToolSnapshot]) -> DoctorCheck {
        guard !tools.isEmpty else {
            return DoctorCheck(
                identifier: .requiredTools,
                status: .degraded,
                message: "Command-line dependency availability was not inspected.",
                remediation: "Rerun doctor where the bounded host tool probe is available."
            )
        }
        let missingRequired = tools.filter { $0.requiredForRuntime && !$0.available }
        let status: DoctorReadinessState = missingRequired.isEmpty
            ? .ready
            : .externallyConstrained
        return DoctorCheck(
            identifier: .requiredTools,
            status: status,
            message: status == .ready
                ? "All runtime-required command-line dependencies are available; optional developer tools are informational."
                : "One or more runtime-required command-line dependencies are unavailable.",
            remediation: status == .ready
                ? nil
                : "Install the missing tools from trusted sources and ensure they are discoverable without unsafe PATH entries.",
            details: Dictionary(uniqueKeysWithValues: tools.map { ($0.identifier, String($0.available)) })
        )
    }

    private static func resourceIntelligenceMessage(for report: ResourceIntelligenceReport) -> String {
        let memoryText = report.hardware.physicalMemoryBytes.map(String.init) ?? "unknown"
        let appleContainerVersion = report.appleContainer.version ?? "unavailable"
        return "Extended host facts were recorded using \(report.measurementMethod.rawValue); physicalMemoryBytes=\(memoryText); Apple container version=\(appleContainerVersion); no capacity guarantee is inferred."
    }
}

public extension DoctorSystemSnapshot {
    static func unavailable(developmentBuild: Bool = true) -> DoctorSystemSnapshot {
        DoctorSystemSnapshot(
            localNetwork: DoctorLocalNetworkSnapshot(
                loopbackAvailable: false,
                activeNonLoopbackInterfaceCount: 0,
                hasIPv4: false,
                hasIPv6: false,
                probeError: "Local network facts were unavailable."
            ),
            signingTrust: DoctorSigningTrustSnapshot(
                codeSignature: .unavailable,
                gatekeeper: .unavailable,
                developmentBuild: developmentBuild,
                probeError: "Signing trust facts were unavailable."
            ),
            resourcePressure: DoctorResourcePressureSnapshot(
                physicalMemoryBytes: 0,
                reclaimableMemoryBytes: nil,
                reclaimableMemoryPercent: nil,
                thermalState: .unknown,
                probeError: "Resource pressure facts were unavailable."
            ),
            tools: []
        )
    }
}
