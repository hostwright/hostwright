import Foundation
import HostwrightRuntime

public enum RuntimeProviderProbeFailure: String, Codable, Equatable, Sendable {
    case componentUnavailable = "component-unavailable"
    case incompatibleComponent = "incompatible-component"
    case platformUnsupported = "platform-unsupported"
    case helperHandshakeUnavailable = "helper-handshake-unavailable"
    case peerAuthenticationFailed = "peer-authentication-failed"
    case staleCapability = "stale-capability"
    case cancelled = "probe-cancelled"
    case probeFailed = "probe-failed"
}

public struct RuntimeProviderProbeResult: Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let snapshot: RuntimeCapabilitySnapshot?
    public let failure: RuntimeProviderProbeFailure?

    public init(
        providerID: RuntimeProviderID,
        snapshot: RuntimeCapabilitySnapshot?,
        failure: RuntimeProviderProbeFailure?
    ) {
        self.providerID = providerID
        self.snapshot = snapshot
        self.failure = failure
    }

    public static func available(_ snapshot: RuntimeCapabilitySnapshot) -> Self {
        Self(
            providerID: snapshot.descriptor.providerID,
            snapshot: snapshot,
            failure: nil
        )
    }

    public static func unavailable(
        _ providerID: RuntimeProviderID,
        reason: RuntimeProviderProbeFailure
    ) -> Self {
        Self(providerID: providerID, snapshot: nil, failure: reason)
    }
}

public enum RuntimeProviderDiscovery {
    public static func liveProbe() async -> [RuntimeProviderProbeResult] {
        let cli: RuntimeProviderProbeResult
        do {
            cli = .available(
                try await RuntimeProviderCapabilityProbe().probeAppleContainerCLI()
            )
        } catch is CancellationError {
            cli = .unavailable(.appleContainerCLI, reason: .cancelled)
        } catch let error as RuntimeProviderCapabilityProbeError {
            cli = .unavailable(.appleContainerCLI, reason: failureReason(for: error))
        } catch {
            cli = .unavailable(.appleContainerCLI, reason: .probeFailed)
        }

        let helper: RuntimeProviderProbeResult
        do {
            let configuration = try ContainerizationHelperClientConfiguration.installed()
            let client = ContainerizationHelperClient(configuration: configuration)
            helper = .available(try await client.negotiate())
        } catch is CancellationError {
            helper = .unavailable(.appleContainerization, reason: .cancelled)
        } catch let error as ContainerizationHelperClientError {
            helper = .unavailable(
                .appleContainerization,
                reason: helperFailureReason(for: error)
            )
        } catch {
            helper = .unavailable(.appleContainerization, reason: .probeFailed)
        }

        return [cli, helper]
    }

    private static func failureReason(
        for error: RuntimeProviderCapabilityProbeError
    ) -> RuntimeProviderProbeFailure {
        switch error {
        case .executableUnavailable, .apiServiceUnavailable,
             .helperPeerIdentityUnavailable:
            return .componentUnavailable
        case .unsupportedMacOSVersion, .unsupportedArchitecture,
             .invalidHostVersion, .invalidHostBuild:
            return .platformUnsupported
        case .helperHandshakeUnavailable:
            return .helperHandshakeUnavailable
        case .helperPeerIdentityInvalid:
            return .peerAuthenticationFailed
        case .helperCapabilityStale:
            return .staleCapability
        case .invalidResolvedExecutable, .invalidProcessResult,
             .invalidCLIIdentity, .invalidAPIServiceIdentity,
             .helperProtocolUnsupported, .helperHostMismatch,
             .helperCapabilityDigestInvalid, .invalidCapability:
            return .incompatibleComponent
        }
    }

    private static func helperFailureReason(
        for error: ContainerizationHelperClientError
    ) -> RuntimeProviderProbeFailure {
        switch error {
        case .peerAuthenticationFailed:
            return .peerAuthenticationFailed
        case .remote(let failure) where failure.category == .staleCapability:
            return .staleCapability
        case .remote(let failure) where failure.category == .incompatible:
            return .incompatibleComponent
        case .cancelled:
            return .cancelled
        case .unsafeExecutable, .unsafeConfiguration, .unsafeRuntimeDirectory,
             .socketUnsafe, .pathNotAbsolute, .pathNotNormalized:
            return .peerAuthenticationFailed
        case .socketUnavailable, .connectionFailed, .helperLaunchFailed,
             .helperExited, .timedOut:
            return .helperHandshakeUnavailable
        case .truncatedResponse, .responseTooLarge, .responseMismatch,
             .replayedResponse, .invalidResponse, .remote:
            return .incompatibleComponent
        }
    }
}

public struct RuntimeProviderDiscoveryEntry: Codable, Equatable, Sendable {
    public let providerID: RuntimeProviderID
    public let state: RuntimeProviderCapabilityState
    public let reasons: [String]
    public let capabilitySHA256: String?
    public let snapshot: RuntimeCapabilitySnapshot?
}

public struct RuntimeProviderAutomaticSelection: Codable, Equatable, Sendable {
    public let state: RuntimeProviderCapabilityState
    public let providerID: RuntimeProviderID?
    public let capabilitySHA256: String?
    public let reason: String
}

public struct RuntimeProvidersReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: String
    public let providers: [RuntimeProviderDiscoveryEntry]
    public let automaticSelection: RuntimeProviderAutomaticSelection
}

struct RuntimeProvidersCommandRunner {
    let output: CLIOutputFormat
    let environment: CLIEnvironment

    func run() throws -> CLIRunResult {
        let probeResults = try hostwrightWaitForAsync {
            await environment.runtimeProviderProbes()
        }
        let report = makeReport(probeResults)
        return CLIRunResult(
            standardOutput: output == .json
                ? CLIJSON.codable(report)
                : render(report)
        )
    }

    private func makeReport(
        _ probeResults: [RuntimeProviderProbeResult]
    ) -> RuntimeProvidersReport {
        let grouped = Dictionary(grouping: probeResults, by: \RuntimeProviderProbeResult.providerID)
        let providers = RuntimeProviderID.knownValues
            .sorted { $0.rawValue < $1.rawValue }
            .map { providerID in
                entry(providerID: providerID, records: grouped[providerID] ?? [])
            }
        let snapshots = providers.compactMap(\.snapshot)
        let automaticSelection: RuntimeProviderAutomaticSelection
        do {
            let selected = try RuntimeProviderSelector.select(
                requested: .automatic,
                existingBinding: nil,
                snapshots: snapshots
            )
            automaticSelection = RuntimeProviderAutomaticSelection(
                state: .available,
                providerID: selected.providerID,
                capabilitySHA256: selected.capabilitySHA256,
                reason: selected.providerID == .appleContainerCLI
                    ? "preferred-compatible-apple-cli"
                    : "fallback-compatible-containerization"
            )
        } catch {
            automaticSelection = RuntimeProviderAutomaticSelection(
                state: .unavailable,
                providerID: nil,
                capabilitySHA256: nil,
                reason: "no-compatible-provider"
            )
        }
        return RuntimeProvidersReport(
            schemaVersion: 1,
            kind: "runtimeProviders",
            providers: providers,
            automaticSelection: automaticSelection
        )
    }

    private func entry(
        providerID: RuntimeProviderID,
        records: [RuntimeProviderProbeResult]
    ) -> RuntimeProviderDiscoveryEntry {
        guard records.count == 1, let record = records.first else {
            return RuntimeProviderDiscoveryEntry(
                providerID: providerID,
                state: .unavailable,
                reasons: [records.isEmpty ? "probe-not-run" : "duplicate-probe-result"],
                capabilitySHA256: nil,
                snapshot: nil
            )
        }
        guard record.failure == nil,
              let snapshot = record.snapshot,
              snapshot.descriptor.providerID == providerID else {
            return RuntimeProviderDiscoveryEntry(
                providerID: providerID,
                state: .unavailable,
                reasons: [record.failure?.rawValue ?? "provider-identity-mismatch"],
                capabilitySHA256: nil,
                snapshot: nil
            )
        }
        let compatibility = RuntimeProviderCapabilityNegotiator.negotiate(
            snapshot,
            expectedProviderID: providerID,
            requiredFeatures: [.observation, .lifecycle]
        )
        return RuntimeProviderDiscoveryEntry(
            providerID: providerID,
            state: compatibility.state,
            reasons: compatibility.findings.isEmpty
                ? ["compatible"]
                : compatibility.findings.map(Self.findingReason),
            capabilitySHA256: snapshot.canonicalSHA256,
            snapshot: snapshot
        )
    }

    private static func findingReason(
        _ finding: RuntimeProviderCompatibilityFinding
    ) -> String {
        [
            finding.reason.rawValue,
            finding.feature?.rawValue,
            finding.component?.rawValue
        ]
        .compactMap { $0 }
        .joined(separator: ":")
    }

    private func render(_ report: RuntimeProvidersReport) -> String {
        let providerLines = report.providers.map { provider in
            let digest = provider.capabilitySHA256 ?? "unavailable"
            return "\(provider.providerID.rawValue)\t\(provider.state.rawValue)\t\(digest)\t\(provider.reasons.joined(separator: ","))"
        }
        let selected = report.automaticSelection.providerID?.rawValue ?? "none"
        return ([
            "Runtime providers",
            "Automatic selection: \(selected) (\(report.automaticSelection.reason))"
        ] + providerLines).joined(separator: "\n") + "\n"
    }
}
