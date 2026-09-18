import Foundation
import HostwrightRuntime

final class ActivationAuthorityTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var denied = false

    func deny() { lock.withLock { denied = true } }

    func validate() throws {
        if lock.withLock({ denied }) {
            throw RuntimeAdapterError.mutationUnavailableByPolicy("Admission expired during provider preparation.")
        }
    }
}

struct DelayedActivationRuntimeRunner: RuntimeProcessRunning {
    let base: any RuntimeProcessRunning
    let gate: ActivationAuthorityTestGate
    let invalidateAfter: @Sendable (RuntimeCommandSpec) -> Bool

    func run(_ spec: RuntimeCommandSpec) async throws -> RuntimeCommandResult {
        let result = try await base.run(spec)
        if invalidateAfter(spec) {
            try await Task.sleep(for: .milliseconds(10))
            gate.deny()
        }
        return result
    }
}
