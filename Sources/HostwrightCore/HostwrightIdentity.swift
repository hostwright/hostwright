import Foundation

public enum HostwrightIdentity {
    public static let projectName = "Hostwright"
    public static let cliName = "hostwright"
    public static let daemonName = "hostwrightd"
    public static let manifestFileName = "hostwright.yaml"
    public static let domain = "hostwright.dev"
    public static let description = "Mac-native desired-state control plane for Apple container workloads."
    public static let tagline = "Desired-state container control for Apple silicon Macs."
    public static let version = "0.1.0-alpha.1"
}

public enum HostwrightErrorCode: String, Sendable {
    case commandUsage = "HW-CLI-001"
    case fileAlreadyExists = "HW-CLI-002"
    case confirmationMismatch = "HW-CLI-003"
    case partialFailure = "HW-CLI-004"
    case unsupportedArchitecture = "HW-COMPAT-001"
    case unsupportedMacOSVersion = "HW-COMPAT-002"
    case runtimeUnavailable = "HW-RUNTIME-001"
    case runtimeMutationNotImplemented = "HW-RUNTIME-002"
    case manifestParseFailed = "HW-MANIFEST-001"
    case manifestValidationFailed = "HW-MANIFEST-002"
    case manifestUnsupportedFeature = "HW-MANIFEST-003"
    case manifestFileIOFailed = "HW-MANIFEST-004"
    case stateStoreUnavailable = "HW-STATE-001"
    case unsafeExposure = "HW-SECURITY-001"
}

public struct HostwrightDiagnostic: Equatable, Sendable {
    public let code: HostwrightErrorCode
    public let message: String

    public init(code: HostwrightErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum HostwrightPathPolicy {
    public static func isHostRootMountSource(_ source: String) -> Bool {
        let normalized = normalizedAbsoluteMountSource(source)
        return normalized == "/"
    }

    public static func containsParentDirectoryTraversal(_ source: String) -> Bool {
        mountSourceComponents(source).contains("..")
    }

    private static func normalizedAbsoluteMountSource(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }

        var stack: [String] = []
        for component in mountSourceComponents(trimmed) {
            if component == "." {
                continue
            }

            if component == ".." {
                if !stack.isEmpty {
                    stack.removeLast()
                }
                continue
            }

            stack.append(component)
        }

        return stack.isEmpty ? "/" : "/" + stack.joined(separator: "/")
    }

    private static func mountSourceComponents(_ source: String) -> [String] {
        source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

public struct PlatformSnapshot: Equatable, Sendable {
    public let macOSMajorVersion: Int
    public let architecture: String

    public init(macOSMajorVersion: Int, architecture: String) {
        self.macOSMajorVersion = macOSMajorVersion
        self.architecture = architecture
    }

    public static var current: PlatformSnapshot {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        return PlatformSnapshot(macOSMajorVersion: version.majorVersion, architecture: architecture)
    }
}

public enum CompatibilityGate {
    public static let minimumMacOSMajorVersion = 26
    public static let supportedArchitecture = "arm64"

    public static func evaluate(_ snapshot: PlatformSnapshot) -> [HostwrightDiagnostic] {
        var diagnostics: [HostwrightDiagnostic] = []

        if snapshot.architecture != supportedArchitecture {
            diagnostics.append(
                HostwrightDiagnostic(
                    code: .unsupportedArchitecture,
                    message: "Hostwright first-release support requires Apple silicon."
                )
            )
        }

        if snapshot.macOSMajorVersion < minimumMacOSMajorVersion {
            diagnostics.append(
                HostwrightDiagnostic(
                    code: .unsupportedMacOSVersion,
                    message: "Hostwright first-release support requires macOS 26 or newer."
                )
            )
        }

        return diagnostics
    }
}

public struct HostwrightServiceReference: Equatable, Hashable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }
}
