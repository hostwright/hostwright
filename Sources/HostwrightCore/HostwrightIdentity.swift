import Foundation

public enum HostwrightIdentity {
    public static let projectName = "Hostwright"
    public static let cliName = "hostwright"
    public static let daemonName = "hostwrightd"
    public static let manifestFileName = "hostwright.yaml"
    public static let domain = "hostwright.dev"
    public static let description = "Mac-native desired-state control plane for Apple container workloads."
    public static let tagline = "Desired-state container control for Apple silicon Macs."
    public static let version = "0.0.2-dev.14"
    public static let releaseTarget = "v0.0.2"
}

public enum HostwrightErrorCode: String, Sendable {
    case commandUsage = "HW-CLI-001"
    case fileAlreadyExists = "HW-CLI-002"
    case confirmationMismatch = "HW-CLI-003"
    case partialFailure = "HW-CLI-004"
    case fileIOFailed = "HW-CLI-005"
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
    case teamProfileInvalid = "HW-TEAM-001"
    case teamApprovalInvalid = "HW-TEAM-002"
    case teamBindingMismatch = "HW-TEAM-003"
    case benchmarkInvalid = "HW-BENCH-001"
    case benchmarkBlocked = "HW-BENCH-002"
    case benchmarkFailed = "HW-BENCH-003"
    case extensionInvalid = "HW-EXT-001"
    case extensionBlocked = "HW-EXT-002"
    case extensionExecutionFailed = "HW-EXT-003"
    case controlAPIInvalid = "HW-API-001"
    case controlAPIUnavailable = "HW-API-002"
    case controlAPIExecutionFailed = "HW-API-003"
    case secretInvalid = "HW-SECRET-001"
    case secretUnavailable = "HW-SECRET-002"
    case secretNotFound = "HW-SECRET-003"
    case secretConflict = "HW-SECRET-004"
    case secretDenied = "HW-SECRET-005"
    case secretCancelled = "HW-SECRET-006"
    case secretPartialEffect = "HW-SECRET-007"
    case registryInvalid = "HW-REGISTRY-001"
    case registryCredentialUnavailable = "HW-REGISTRY-002"
    case registryAuthenticationDenied = "HW-REGISTRY-003"
    case registryTransportUnavailable = "HW-REGISTRY-004"
    case registryScopeDenied = "HW-REGISTRY-005"
    case registryCancelled = "HW-REGISTRY-006"
    case registryPartialEffect = "HW-REGISTRY-007"
    case imageInvalid = "HW-IMAGE-001"
    case imageUnavailable = "HW-IMAGE-002"
    case imageConflict = "HW-IMAGE-003"
    case imageDenied = "HW-IMAGE-004"
    case imageCancelled = "HW-IMAGE-005"
    case imagePartialEffect = "HW-IMAGE-006"
    case storageInvalid = "HW-STORAGE-001"
    case storageUnavailable = "HW-STORAGE-002"
    case storageConflict = "HW-STORAGE-003"
    case storageDenied = "HW-STORAGE-004"
    case storageCancelled = "HW-STORAGE-005"
    case storagePartialEffect = "HW-STORAGE-006"
    case daemonInvalid = "HW-DAEMON-101"
    case daemonUnavailable = "HW-DAEMON-102"
    case daemonConflict = "HW-DAEMON-103"
    case daemonDenied = "HW-DAEMON-104"
    case daemonCancelled = "HW-DAEMON-105"
    case daemonPartialEffect = "HW-DAEMON-106"
}

public struct HostwrightDiagnostic: Error, Equatable, Sendable {
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
