import HostwrightCore

public enum DoctorCheckIdentifier: String, Equatable, Sendable {
    case operatingSystem
    case appleSilicon
    case macOSVersion
    case swiftToolchain
    case appleContainerCLI
    case manifestPresence
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

    public init(checks: [DoctorCheck]) {
        self.checks = checks
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

    public init(
        operatingSystemDescription: String,
        platform: PlatformSnapshot,
        swiftVersion: String?,
        containerExecutablePath: String?,
        manifestExists: Bool
    ) {
        self.operatingSystemDescription = operatingSystemDescription
        self.platform = platform
        self.swiftVersion = swiftVersion
        self.containerExecutablePath = containerExecutablePath
        self.manifestExists = manifestExists
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

        return DoctorReport(checks: checks)
    }
}
