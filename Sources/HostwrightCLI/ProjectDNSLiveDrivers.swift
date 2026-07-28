import CryptoKit
import Foundation
import HostwrightCore
import HostwrightNetworkHelperCore
import HostwrightNetworking
import HostwrightRuntime

struct LiveProjectDNSHelperDriver: ProjectDNSHelperDriving {
    private let client: NetworkHelperClient

    init(
        environment: CLIEnvironment,
        stateDatabasePath: String?
    ) throws {
        guard let hostExecutable = Bundle.main.executableURL else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Project DNS could not resolve the Hostwright executable location."
            )
        }
        let resolution = try environment.localPathResolution(
            stateDatabasePath
        )
        let configuration = NetworkHelperClientConfiguration(
            executableURL: hostExecutable
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "hostwright-network-helper",
                    isDirectory: false
                ),
            runtimeDirectoryURL: URL(
                fileURLWithPath:
                    resolution.layout.runtimeDirectory,
                isDirectory: true
            ).appendingPathComponent(
                "network-helper",
                isDirectory: true
            )
        )
        client = NetworkHelperClient(configuration: configuration)
    }

    func status(
        identity: ProjectDNSHelperIdentity
    ) async throws -> ProjectDNSHelperObservation {
        let status = try await client.status(
            identity: try helperIdentity(identity)
        )
        return observation(status)
    }

    func apply(
        identity: ProjectDNSHelperIdentity,
        corefile: String,
        hostAccessBindings: [ProjectDNSHostAccessBinding],
        predecessorFencingToken: String?
    ) async throws -> ProjectDNSHelperObservation {
        let active = try await client.apply(
            identity: try helperIdentity(identity),
            corefile: corefile,
            hostAccessBindings: hostAccessBindings,
            predecessorFencingToken:
                predecessorFencingToken
        )
        return ProjectDNSHelperObservation(
            disposition: .active,
            corefilePath: active.url.path,
            corefileSHA256: active.sha256,
            hostAccessSHA256: active.hostAccessSHA256
        )
    }

    func remove(
        identity: ProjectDNSHelperIdentity
    ) async throws -> ProjectDNSHelperObservation {
        try await client.remove(
            identity: try helperIdentity(identity)
        )
        return ProjectDNSHelperObservation(
            disposition: .absent,
            corefilePath: nil,
            corefileSHA256: nil
        )
    }

    private func helperIdentity(
        _ identity: ProjectDNSHelperIdentity
    ) throws -> NetworkHelperDNSIdentity {
        guard let generation = Int(exactly: identity.generation) else {
            throw HostwrightDiagnostic(
                code: .runtimeUnavailable,
                message:
                    "Project DNS helper generation exceeds the supported platform integer range."
            )
        }
        return NetworkHelperDNSIdentity(
            projectUUID: identity.projectUUID,
            dnsUUID: identity.dnsUUID,
            generation: generation,
            fencingToken: identity.fencingToken
        )
    }

    private func observation(
        _ status: NetworkHelperClientStatus
    ) -> ProjectDNSHelperObservation {
        let disposition: ProjectDNSHelperDisposition
        switch status.disposition {
        case .absent:
            disposition = .absent
        case .active:
            disposition = .active
        case .conflict:
            disposition = .conflicting
        case .quarantined:
            disposition = .quarantined
        }
        return ProjectDNSHelperObservation(
            disposition: disposition,
            corefilePath: status.activeCorefile?.url.path,
            corefileSHA256: status.activeCorefile?.sha256,
            hostAccessSHA256:
                status.activeCorefile?.hostAccessSHA256
        )
    }
}

struct LiveProjectDNSRuntimeDriver: ProjectDNSRuntimeDriving {
    let adapter: any RuntimeAdapter

    func currentCapabilitySHA256() async throws -> String {
        try await adapter.capabilitySnapshot().canonicalSHA256
    }

    func coreDNSImageEvidence()
        async throws -> CoreDNSInfrastructureImageEvidence
    {
        let reference =
            CoreDNSInfrastructureImage
                .immutableLinuxARM64Reference
        let evidence = try await adapter.localImageEvidence(
            for: reference
        )
        let exactPlatformContent =
            evidence.reference == reference &&
            evidence.variantDigest ==
                CoreDNSInfrastructureImage.linuxARM64Digest &&
            evidence.operatingSystem == "linux" &&
            evidence.architecture == "arm64"
        return CoreDNSInfrastructureImageEvidence(
            resolvedReference: evidence.reference,
            descriptorDigest: evidence.descriptorDigest,
            variantDigest: evidence.variantDigest,
            operatingSystem: evidence.operatingSystem,
            architecture: evidence.architecture,
            localImageAvailable: true,
            phase05PolicyAccepted: exactPlatformContent,
            evidenceSHA256: digest(evidence)
        )
    }

    func inventory() async throws -> RuntimeInventory {
        try await adapter.inventory()
    }

    func mutate(
        _ mutation: ProjectDNSRuntimeMutation
    ) async throws {
        let action: PlannedRuntimeAction
        let context: RuntimeMutationContext
        let planSHA256: String
        switch mutation {
        case .create(
            let service,
            let resourceIdentifier,
            let mutationContext,
            let plan
        ):
            action = PlannedRuntimeAction(
                kind: .create,
                identity: service.identity,
                resourceIdentifier: resourceIdentifier,
                isDestructive: false,
                summary: "Create the UUID-owned project DNS service.",
                desiredService: service
            )
            context = mutationContext
            planSHA256 = plan
        case .start(
            let identity,
            let resourceIdentifier,
            let mutationContext,
            let plan
        ):
            action = PlannedRuntimeAction(
                kind: .start,
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                isDestructive: false,
                summary: "Start the UUID-owned project DNS service."
            )
            context = mutationContext
            planSHA256 = plan
        case .stop(
            let identity,
            let resourceIdentifier,
            let expectedOwnership,
            let mutationContext,
            let plan
        ):
            let matches = try await adapter.inventory()
                .containers.filter {
                    $0.runtimeID == resourceIdentifier ||
                        $0.ownership?.resourceUUID ==
                            expectedOwnership.resourceUUID
                }
            guard matches.count == 1,
                  matches[0].runtimeID == resourceIdentifier,
                  matches[0].ownership == expectedOwnership else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Project DNS stop refused because exact runtime ownership changed."
                )
            }
            action = PlannedRuntimeAction(
                kind: .stop,
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                isDestructive: true,
                summary:
                    "Stop the exact UUID-owned project DNS service before removal."
            )
            context = mutationContext
            planSHA256 = plan
        case .remove(
            let identity,
            let resourceIdentifier,
            let expectedOwnership,
            let mutationContext,
            let plan
        ):
            let matches = try await adapter.inventory()
                .containers.filter {
                    $0.runtimeID == resourceIdentifier ||
                        $0.ownership?.resourceUUID ==
                            expectedOwnership.resourceUUID
                }
            guard matches.count == 1,
                  matches[0].runtimeID == resourceIdentifier,
                  matches[0].ownership == expectedOwnership else {
                throw HostwrightDiagnostic(
                    code: .runtimeUnavailable,
                    message:
                        "Project DNS removal refused because exact runtime ownership changed."
                )
            }
            action = PlannedRuntimeAction(
                kind: .remove,
                identity: identity,
                resourceIdentifier: resourceIdentifier,
                isDestructive: true,
                summary: "Remove the exact UUID-owned project DNS service."
            )
            context = mutationContext
            planSHA256 = plan
        }
        _ = try await adapter.execute(
            action,
            confirmation: RuntimeMutationConfirmation(
                confirmed: true,
                reason: "Confirmed project DNS lifecycle plan",
                planHash: planSHA256,
                context: context
            )
        )
    }

    private func digest(
        _ evidence: RuntimeLocalImageEvidence
    ) -> String {
        let bytes = [
            evidence.reference,
            evidence.descriptorDigest,
            evidence.variantDigest,
            evidence.operatingSystem,
            evidence.architecture,
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(bytes.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
