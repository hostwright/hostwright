import Foundation
import HostwrightCLI
import HostwrightCommandTransport
import HostwrightControlPlane
import HostwrightCore
import HostwrightDaemonCore
import HostwrightManifest
import HostwrightPolicy
import HostwrightReconciler
import HostwrightState

struct LocalLifecycleDaemonReconciler: DaemonReconciliationDriving {
    let environment: CLIEnvironment

    init(environment: CLIEnvironment = .live) {
        self.environment = environment
    }

    func lifecycleManifestSHA256(text: String, manifest: HostwrightManifest) throws -> String {
        try HostwrightLifecycleManifestDigest.sha256(text: text, manifest: manifest)
    }

    func reconcile(request: DaemonReconciliationRequest) async throws -> DaemonReconciliationResult {
        guard let binding = request.schedulerAuthorityBinding else {
            return try await UnattendedLifecycleReconciler(environment: environment).reconcile(request: request)
        }
        return try await reconcileAuthorized(request: request, schedulerAuthorityBinding: binding)
    }

    func reconcileAuthorized(
        request: DaemonReconciliationRequest,
        schedulerAuthorityBinding binding: DaemonSchedulerAuthorityBinding
    ) async throws -> DaemonReconciliationResult {
        guard request.schedulerAuthorityBinding == binding else {
            throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-authority")
        }
        guard let local = binding.localLifecycleAuthority, !local.entries.isEmpty,
              request.selectedServiceNames?.isEmpty != true else {
            return try await UnattendedLifecycleReconciler(environment: environment)
                .reconcileAuthorized(request: request, schedulerAuthorityBinding: binding)
        }
        let store = SQLiteStateStore(path: request.stateDatabasePath)
        let selected = local.entries.filter { entry in
            request.selectedServiceNames?.contains(entry.serviceName) ?? true
        }
        let subjectIDs = Set(selected.map { $0.reservation.ownerSubjectID }).sorted()
        guard subjectIDs.count == 1 else {
            throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-owner-scope")
        }
        let pressure = SchedulerPressureAuthorityCoordinator(
            probe: SchedulerMacOSHostPressureProbe(), repository: store.schedulerAdmissions, clock: Date.init
        )
        let hostContext = LocalLifecycleScheduler.context(
            subjectID: subjectIDs[0], store: store, configPath: request.manifestPath, pressure: pressure
        )
        var authorizedEnvironment = environment
        authorizedEnvironment.lifecycleScheduler = LifecycleSchedulerContext(
            subjectID: hostContext.subjectID,
            authorize: { plan in
                try Self.authorize(plan: plan, request: request, subjectIDs: subjectIDs, store: store)
            },
            refresh: hostContext.refresh
        )
        return try await UnattendedLifecycleReconciler(environment: authorizedEnvironment)
            .reconcileAuthorized(request: request, schedulerAuthorityBinding: binding)
    }

    static func authorize(
        plan: LifecyclePlan, request: DaemonReconciliationRequest,
        subjectIDs: [String], store: SQLiteStateStore
    ) throws {
        guard plan.projectID == request.projectID,
              let local = request.schedulerAuthorityBinding?.localLifecycleAuthority,
              local.sourceManifestSHA256 == request.manifestSHA256,
              plan.manifestSHA256 == local.manifestSHA256,
              plan.projectResourceUUID == local.projectUUID else {
            throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-plan")
        }
        let arguments = ["up", request.manifestPath] + [
            "--state-db", request.stateDatabasePath, "--confirm-plan", plan.planSHA256, "--output", "json"
        ]
        let route = try CLIControlRoute.classify(arguments: arguments).withAuthorizationScope(
            CLIControlAuthorizationScope(projectIdentifier: local.projectUUID, resourceIdentifier: nil)
        )
        let envelope = ControlRequestEnvelope(
            requestID: "daemon-local-\(plan.planSHA256.prefix(24))", operation: route.operation,
            timeoutMilliseconds: 30_000, idempotencyKey: "daemon-local-\(plan.planSHA256)",
            body: route.requestBody()
        )
        let authorizer = RBACAuthorizationEngine(repository: store.rbac)
        let profiles = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
        let admission = AdmissionPolicyEngine(
            repository: store.admission, workloadProfileResolver: { try profiles.resolve(id: $0) }
        )
        for subjectID in subjectIDs {
            guard let identity = try store.controlIdentities.loadIdentity(subjectID), identity.revokedAt == nil else {
                throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-subject")
            }
            if let expiry = identity.credentialExpiresAt {
                guard let date = ISO8601DateFormatter().date(from: expiry), date > Date() else {
                    throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-subject-expired")
                }
            }
            let subject = LocalSubject(
                identifier: subjectID, userID: identity.userID,
                codeIdentityHash: identity.codeIdentity.codeDirectoryHash, credentialID: identity.credentialID
            )
            let decision = try authorizer.authorize(
                subject: subject, request: envelope, authoritativeProjectIdentifier: local.projectUUID, at: Date()
            )
            let evaluated = try admission.evaluate(subjectID: subjectID, request: envelope, at: Date())
            guard decision.effect == .allow, evaluated.allowed, evaluated.effectiveRequest == envelope else {
                throw SchedulerAdmissionError.invalidBinding(field: "daemon-local-policy-denied")
            }
        }
    }
}
