import Foundation
import HostwrightNetworking

/// Holds the exact compiled policy generation that the helper is permitted to
/// enforce. A replacement never leaves the prior generation active.
final class NetworkHelperPolicyBroker: @unchecked Sendable {
    private struct Configuration: Equatable {
        let plan: NetworkPolicyPlan
    }

    private let lock = NSLock()
    private var configurations: [NetworkHelperDNSIdentity: Configuration] = [:]

    var hasActivePolicies: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !configurations.isEmpty
    }

    @discardableResult
    func apply(
        identity: NetworkHelperDNSIdentity,
        plan: NetworkPolicyPlan
    ) throws -> String {
        try Self.validated(plan: plan, identity: identity)
        lock.lock()
        defer { lock.unlock() }
        configurations = configurations.filter { existing, _ in
            existing.projectUUID != identity.projectUUID ||
                existing.dnsUUID != identity.dnsUUID ||
                existing == identity
        }
        configurations[identity] = Configuration(plan: plan)
        return plan.sha256
    }

    func remove(identity: NetworkHelperDNSIdentity) {
        lock.lock()
        defer { lock.unlock() }
        configurations.removeValue(forKey: identity)
    }

    func sha256(identity: NetworkHelperDNSIdentity) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return configurations[identity]?.plan.sha256
    }

    func allows(
        identity: NetworkHelperDNSIdentity,
        flow: NetworkPolicyFlow
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return configurations[identity]?.plan.allows(flow) ?? false
    }

    func allows(
        identity: NetworkHelperDNSIdentity,
        expectedSHA256: String,
        flow: NetworkPolicyFlow
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let plan = configurations[identity]?.plan,
              plan.sha256 == expectedSHA256 else {
            return false
        }
        return plan.allows(flow)
    }

    static func validated(
        plan: NetworkPolicyPlan,
        identity: NetworkHelperDNSIdentity
    ) throws {
        guard plan.projectUUID == identity.projectUUID,
              plan.generation == identity.generation,
              plan.services.allSatisfy({ !$0.serviceName.isEmpty }) else {
            throw NetworkHelperError.invalidRequest
        }
        let rebuilt = try NetworkPolicyPlan(
            projectName: plan.projectName,
            projectUUID: plan.projectUUID,
            generation: plan.generation,
            services: plan.services
        )
        guard rebuilt.sha256 == plan.sha256 else {
            throw NetworkHelperError.invalidRequest
        }
    }
}
