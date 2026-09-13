import CryptoKit
import Foundation
import HostwrightRuntime
import HostwrightState

public enum LifecycleSchedulerRuntimeState: String, Codable, Sendable {
    case running
    case inactive
    case absent
    case unknown
}

public struct LifecycleSchedulerRuntimeObservation: Sendable {
    public let state: LifecycleSchedulerRuntimeState
    public let evidenceDigest: String

    public static func observe(
        expected: SchedulerRuntimeOwnershipBinding,
        inventory: RuntimeInventory
    ) throws -> LifecycleSchedulerRuntimeObservation {
        let state = classify(expected: expected, inventory: inventory)
        struct Evidence: Encodable {
            let expected: SchedulerRuntimeOwnershipBinding
            let inventorySHA256: String
            let executionState: LifecycleSchedulerRuntimeState
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let digest = SHA256.hash(data: try encoder.encode(Evidence(
            expected: expected, inventorySHA256: inventory.semanticSHA256, executionState: state
        ))).map { String(format: "%02x", $0) }.joined()
        return LifecycleSchedulerRuntimeObservation(state: state, evidenceDigest: digest)
    }

    private static func classify(
        expected: SchedulerRuntimeOwnershipBinding, inventory: RuntimeInventory
    ) -> LifecycleSchedulerRuntimeState {
        let authority: RuntimeInventoryAuthority = expected.providerID == .appleContainerCLI
            ? .appleContainerCLIRuntimeList : .appleContainerizationRuntimeList
        guard inventory.authority == authority,
              inventory.machine.state == .running,
              inventory.machine.architecture == "arm64",
              !inventory.machine.operatingSystem.isEmpty,
              inventory.machine.runtimeVersion == expected.providerVersion,
              inventory.machine.services.contains(where: { $0.required && $0.state == .running }),
              inventory.machine.services.allSatisfy({
                  $0.required ? $0.state == .running : $0.state != .unknown
              }) else { return .unknown }
        let candidates = inventory.containers.filter { container in
            container.name == expected.resourceIdentifier ||
                container.ownership?.resourceUUID == expected.resourceUUID ||
                container.labels.contains(where: {
                    ($0.key == RuntimeManagedResourceIdentity.resourceIdentifierLabel &&
                        $0.value == expected.resourceIdentifier) ||
                    ($0.key == RuntimeManagedResourceIdentity.resourceUUIDLabel &&
                        $0.value.lowercased() == expected.resourceUUID)
                })
        }
        guard candidates.count <= 1 else { return .unknown }
        guard let candidate = candidates.first else { return .absent }
        let labels = Dictionary(uniqueKeysWithValues: candidate.labels.map { ($0.key, $0.value) })
        let identity = RuntimeManagedResourceIdentity.identity(from: labels)
        guard let ownership = candidate.ownership,
              ownership.resourceUUID == expected.resourceUUID,
              ownership.projectUUID == expected.projectUUID,
              ownership.projectGeneration == Int(expected.projectGeneration),
              ownership.providerID == expected.providerID,
              ownership.providerGeneration == Int(expected.providerGeneration),
              labels[RuntimeManagedResourceIdentity.managedLabel] == "true",
              labels[RuntimeManagedResourceIdentity.identityVersionLabel] == String(expected.identityVersion),
              labels[RuntimeManagedResourceIdentity.resourceIdentifierLabel] == expected.resourceIdentifier,
              identity?.projectName == expected.projectName,
              identity?.serviceName == expected.serviceName,
              identity?.instanceName == expected.instanceName else { return .unknown }
        if ownership.resourceGeneration > Int(expected.resourceGeneration) {
            return .absent
        }
        guard ownership.resourceGeneration == Int(expected.resourceGeneration),
              ownership.fencingToken == expected.fencingToken else {
            return .unknown
        }
        switch candidate.lifecycle {
        case .running: return .running
        case .created, .stopped, .exited: return .inactive
        case .missing: return .absent
        case .failed, .unknown: return .unknown
        }
    }
}
