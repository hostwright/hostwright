import HostwrightReconciler
import HostwrightRuntime
import HostwrightSecrets

extension ApplyCommandRunner {
    func validateCreateOnlyApplySubset(_ service: DesiredRuntimeService) -> String? {
        if !service.mounts.isEmpty {
            return "Create-only apply rejects volumes and mounts."
        }
        if service.ports.contains(where: { ($0.hostPort ?? 0) < 1_024 }) {
            return "Create-only apply rejects privileged host ports."
        }
        if service.ports.contains(where: { $0.bindAddress == "0.0.0.0" || $0.bindAddress == "::" }) {
            return "Create-only apply rejects broad bind addresses."
        }
        if service.image.hasPrefix("-") {
            return "Create-only apply rejects image values beginning with '-'."
        }
        if service.command.contains(where: { $0.hasPrefix("-") }) {
            return "Create-only apply rejects command tokens beginning with '-'."
        }
        if service.environment.contains(where: { $0.secretReference != nil }) {
            return "Create-only apply rejects unresolved secret references."
        }
        return nil
    }

    func resolveSecretReferences(in service: DesiredRuntimeService) throws -> DesiredRuntimeService {
        guard service.environment.contains(where: { $0.secretReference != nil }) else {
            return service
        }

        let store = environment.secretStore()
        let resolvedEnvironment = try service.environment.map { value in
            guard let reference = value.secretReference else {
                return value
            }

            return RuntimeEnvironmentValue(
                name: value.name,
                value: try store.readString(reference: reference),
                isSensitive: true
            )
        }

        return DesiredRuntimeService(
            identity: service.identity,
            image: service.image,
            command: service.command,
            environment: resolvedEnvironment,
            ports: service.ports,
            mounts: service.mounts,
            healthCheck: service.healthCheck,
            restartPolicy: service.restartPolicy
        )
    }

    func runtimeAction(for action: PlannedAction, desiredService: DesiredRuntimeService?) -> PlannedRuntimeAction {
        switch action.executionAvailability {
        case .availableForCreateMissingService:
            return PlannedRuntimeAction(
                kind: .create,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "Create missing service \(action.identity.displayName).",
                desiredService: desiredService
            )
        case .availableForStartManagedService:
            return PlannedRuntimeAction(
                kind: .start,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "Start managed service \(action.identity.displayName)."
            )
        case .availableForRestartManagedService:
            return PlannedRuntimeAction(
                kind: .restart,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: true,
                summary: "Restart unhealthy Hostwright-owned running service \(action.identity.displayName)."
            )
        case .unavailable:
            return PlannedRuntimeAction(
                kind: .noOp,
                identity: action.identity,
                resourceIdentifier: action.resourceIdentifier,
                isDestructive: false,
                summary: "No runtime action is available."
            )
        }
    }
}
