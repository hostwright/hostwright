import Darwin
import Foundation
import HostwrightCore

public enum DoctorCodeSignatureState: String, Codable, Equatable, Sendable {
    case developerID = "developer-id"
    case adHoc = "ad-hoc"
    case signedOther = "signed-other"
    case unsigned
    case invalid
    case unavailable
}

public enum DoctorGatekeeperState: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
    case unavailable
}

public struct DoctorSigningTrustSnapshot: Codable, Equatable, Sendable {
    public let codeSignature: DoctorCodeSignatureState
    public let gatekeeper: DoctorGatekeeperState
    public let developmentBuild: Bool
    public let probeError: String?

    public init(
        codeSignature: DoctorCodeSignatureState,
        gatekeeper: DoctorGatekeeperState,
        developmentBuild: Bool,
        probeError: String? = nil
    ) {
        self.codeSignature = codeSignature
        self.gatekeeper = gatekeeper
        self.developmentBuild = developmentBuild
        self.probeError = probeError
    }
}

public struct DoctorLocalNetworkSnapshot: Codable, Equatable, Sendable {
    public let loopbackAvailable: Bool
    public let activeNonLoopbackInterfaceCount: Int
    public let hasIPv4: Bool
    public let hasIPv6: Bool
    public let authorizationWasProbed: Bool
    public let probeError: String?

    public init(
        loopbackAvailable: Bool,
        activeNonLoopbackInterfaceCount: Int,
        hasIPv4: Bool,
        hasIPv6: Bool,
        authorizationWasProbed: Bool = false,
        probeError: String? = nil
    ) {
        self.loopbackAvailable = loopbackAvailable
        self.activeNonLoopbackInterfaceCount = activeNonLoopbackInterfaceCount
        self.hasIPv4 = hasIPv4
        self.hasIPv6 = hasIPv6
        self.authorizationWasProbed = authorizationWasProbed
        self.probeError = probeError
    }
}

public struct DoctorResourcePressureSnapshot: Codable, Equatable, Sendable {
    public let physicalMemoryBytes: UInt64
    public let reclaimableMemoryBytes: UInt64?
    public let reclaimableMemoryPercent: Double?
    public let thermalState: ResourcePressureLevel
    public let probeError: String?

    public init(
        physicalMemoryBytes: UInt64,
        reclaimableMemoryBytes: UInt64?,
        reclaimableMemoryPercent: Double?,
        thermalState: ResourcePressureLevel,
        probeError: String? = nil
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.reclaimableMemoryBytes = reclaimableMemoryBytes
        self.reclaimableMemoryPercent = reclaimableMemoryPercent
        self.thermalState = thermalState
        self.probeError = probeError
    }
}

public struct DoctorToolSnapshot: Codable, Equatable, Sendable {
    public let identifier: String
    public let available: Bool
    public let requiredForRuntime: Bool

    public init(identifier: String, available: Bool, requiredForRuntime: Bool) {
        self.identifier = identifier
        self.available = available
        self.requiredForRuntime = requiredForRuntime
    }
}

public struct DoctorSystemSnapshot: Codable, Equatable, Sendable {
    public let localNetwork: DoctorLocalNetworkSnapshot
    public let signingTrust: DoctorSigningTrustSnapshot
    public let resourcePressure: DoctorResourcePressureSnapshot
    public let tools: [DoctorToolSnapshot]

    public init(
        localNetwork: DoctorLocalNetworkSnapshot,
        signingTrust: DoctorSigningTrustSnapshot,
        resourcePressure: DoctorResourcePressureSnapshot,
        tools: [DoctorToolSnapshot]
    ) {
        self.localNetwork = localNetwork
        self.signingTrust = signingTrust
        self.resourcePressure = resourcePressure
        self.tools = tools.sorted { $0.identifier < $1.identifier }
    }
}

public enum DoctorSystemProbe {
    public static func current(
        executablePath: String,
        developmentBuild: Bool,
        containerExecutablePath: String?,
        swiftExecutablePath: String?
    ) -> DoctorSystemSnapshot {
        DoctorSystemSnapshot(
            localNetwork: localNetworkSnapshot(),
            signingTrust: signingSnapshot(
                executablePath: executablePath,
                developmentBuild: developmentBuild
            ),
            resourcePressure: resourcePressureSnapshot(),
            tools: [
                DoctorToolSnapshot(
                    identifier: "apple-container-cli",
                    available: containerExecutablePath != nil,
                    requiredForRuntime: true
                ),
                DoctorToolSnapshot(
                    identifier: "codesign",
                    available: FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
                    requiredForRuntime: false
                ),
                DoctorToolSnapshot(
                    identifier: "gatekeeper-spctl",
                    available: FileManager.default.isExecutableFile(atPath: "/usr/sbin/spctl"),
                    requiredForRuntime: false
                ),
                DoctorToolSnapshot(
                    identifier: "swift-toolchain",
                    available: swiftExecutablePath != nil,
                    requiredForRuntime: false
                )
            ]
        )
    }

    private static func localNetworkSnapshot() -> DoctorLocalNetworkSnapshot {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else {
            return DoctorLocalNetworkSnapshot(
                loopbackAvailable: false,
                activeNonLoopbackInterfaceCount: 0,
                hasIPv4: false,
                hasIPv6: false,
                probeError: "getifaddrs failed with errno \(errno)"
            )
        }
        defer { freeifaddrs(first) }

        var loopbackAvailable = false
        var activeInterfaces = Set<String>()
        var hasIPv4 = false
        var hasIPv6 = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0 else { continue }
            let isLoopback = flags & IFF_LOOPBACK != 0
            if isLoopback {
                loopbackAvailable = true
            } else if flags & IFF_RUNNING != 0 {
                activeInterfaces.insert(String(cString: interface.ifa_name))
            }
            guard let address = interface.ifa_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if !isLoopback { hasIPv4 = true }
            case AF_INET6:
                if !isLoopback { hasIPv6 = true }
            default:
                break
            }
        }
        return DoctorLocalNetworkSnapshot(
            loopbackAvailable: loopbackAvailable,
            activeNonLoopbackInterfaceCount: activeInterfaces.count,
            hasIPv4: hasIPv4,
            hasIPv6: hasIPv6
        )
    }

    private static func resourcePressureSnapshot() -> DoctorResourcePressureSnapshot {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let pageResult = host_page_size(host, &pageSize)
        let statisticsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard pageResult == KERN_SUCCESS, statisticsResult == KERN_SUCCESS else {
            return DoctorResourcePressureSnapshot(
                physicalMemoryBytes: physicalMemory,
                reclaimableMemoryBytes: nil,
                reclaimableMemoryPercent: nil,
                thermalState: ResourcePressureLevel(
                    processInfoThermalState: ProcessInfo.processInfo.thermalState
                ),
                probeError: "Mach VM statistics were unavailable"
            )
        }

        let reclaimablePages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
        let (reclaimableBytes, overflow) = reclaimablePages.multipliedReportingOverflow(
            by: UInt64(pageSize)
        )
        let boundedBytes = overflow ? UInt64.max : reclaimableBytes
        let percent = physicalMemory == 0
            ? nil
            : Double(min(boundedBytes, physicalMemory)) / Double(physicalMemory) * 100
        return DoctorResourcePressureSnapshot(
            physicalMemoryBytes: physicalMemory,
            reclaimableMemoryBytes: boundedBytes,
            reclaimableMemoryPercent: percent,
            thermalState: ResourcePressureLevel(
                processInfoThermalState: ProcessInfo.processInfo.thermalState
            )
        )
    }

    private static func signingSnapshot(
        executablePath: String,
        developmentBuild: Bool
    ) -> DoctorSigningTrustSnapshot {
        let resolvedPath = URL(fileURLWithPath: executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard resolvedPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: resolvedPath) else {
            return DoctorSigningTrustSnapshot(
                codeSignature: .unavailable,
                gatekeeper: .unavailable,
                developmentBuild: developmentBuild,
                probeError: "the running executable path could not be resolved"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign"),
              FileManager.default.isExecutableFile(atPath: "/usr/sbin/spctl") else {
            return DoctorSigningTrustSnapshot(
                codeSignature: .unavailable,
                gatekeeper: .unavailable,
                developmentBuild: developmentBuild,
                probeError: "macOS code-signing verification tools are unavailable"
            )
        }

        do {
            let runner = SecureSubprocessRunner()
            let verification = try runner.run(
                signingRequest(
                    executablePath: "/usr/bin/codesign",
                    arguments: ["--verify", "--strict", "--verbose=2", resolvedPath]
                )
            )
            let display = try runner.run(
                signingRequest(
                    executablePath: "/usr/bin/codesign",
                    arguments: ["--display", "--verbose=4", resolvedPath]
                )
            )
            let assessment = try runner.run(
                signingRequest(
                    executablePath: "/usr/sbin/spctl",
                    arguments: ["--assess", "--type", "execute", "--verbose=4", resolvedPath]
                )
            )
            let displayText = String(decoding: display.standardOutput + display.standardError, as: UTF8.self)
            let verificationText = String(
                decoding: verification.standardOutput + verification.standardError,
                as: UTF8.self
            )
            let signature: DoctorCodeSignatureState
            if verification.exitStatus == 0, displayText.contains("Signature=adhoc") {
                signature = .adHoc
            } else if verification.exitStatus == 0,
                      displayText.contains("Authority=Developer ID Application:") {
                signature = .developerID
            } else if verification.exitStatus == 0 {
                signature = .signedOther
            } else if verificationText.localizedCaseInsensitiveContains("not signed")
                || displayText.localizedCaseInsensitiveContains("not signed") {
                signature = .unsigned
            } else {
                signature = .invalid
            }
            return DoctorSigningTrustSnapshot(
                codeSignature: signature,
                gatekeeper: assessment.exitStatus == 0 ? .accepted : .rejected,
                developmentBuild: developmentBuild
            )
        } catch {
            return DoctorSigningTrustSnapshot(
                codeSignature: .unavailable,
                gatekeeper: .unavailable,
                developmentBuild: developmentBuild,
                probeError: "the bounded signing trust probe failed"
            )
        }
    }

    private static func signingRequest(
        executablePath: String,
        arguments: [String]
    ) -> SecureSubprocessRequest {
        SecureSubprocessRequest(
            executablePath: executablePath,
            arguments: arguments,
            environment: SecureSubprocessEnvironment.currentUser,
            workingDirectory: "/",
            timeoutMilliseconds: 5_000,
            maximumStandardOutputBytes: 64 * 1_024,
            maximumStandardErrorBytes: 64 * 1_024
        )
    }
}
