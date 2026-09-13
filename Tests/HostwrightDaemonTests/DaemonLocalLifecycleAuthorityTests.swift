import CryptoKit
import Foundation
import XCTest
@testable import HostwrightCLI
@testable import HostwrightControlPlane
@testable import HostwrightCore
@testable import HostwrightDaemon
@testable import HostwrightDaemonCore
@testable import HostwrightManifest
@testable import HostwrightReconciler
@testable import HostwrightRuntime
@testable import HostwrightScheduler
@testable import HostwrightState

final class DaemonLocalLifecycleAuthorityTests: XCTestCase {
    func testSuccessfulRunIntentBindsExactHistoryAndRevalidates() throws {
        try withFixture { fixture in
            let authority = try XCTUnwrap(fixture.resolve())
            XCTAssertEqual(authority.entries.count, 1)
            XCTAssertEqual(authority.entries.first?.reservation.runtimeOwnership, fixture.binding)
            XCTAssertEqual(authority.entries.first?.reservation.status, .committed)
            XCTAssertEqual(authority.entries.first?.planSHA256, fixture.initialPlan.planSHA256)
            try authority.revalidate(store: fixture.store, manifest: fixture.manifest, projectID: fixture.projectID)
            let encoded = try JSONEncoder().encode(authority)
            XCTAssertEqual(try JSONDecoder().decode(DaemonLocalLifecycleAuthority.self, from: encoded), authority)
        }
    }

    func testExplicitDownStopRemoveAndInteractiveRunSuppressRecovery() throws {
        for command: LifecycleCommand in [.down, .stop, .remove, .run] {
            try withFixture { fixture in
                let before = try XCTUnwrap(fixture.resolve())
                try fixture.addGroup(command: command)
                let paused = try XCTUnwrap(fixture.resolve())
                XCTAssertTrue(paused.entries.isEmpty, command.rawValue)
                XCTAssertThrowsError(try before.revalidate(
                    store: fixture.store, manifest: fixture.manifest, projectID: fixture.projectID
                ))
            }
        }
    }

    func testReleasedReservationIsHistoricalIntentWithoutReacquiringCapacity() throws {
        try withFixture { fixture in
            try fixture.release()
            let authority = try XCTUnwrap(fixture.resolve())
            XCTAssertEqual(authority.entries.first?.reservation.status, .released)
            XCTAssertEqual(authority.entries.first?.reservation.runtimeOwnership, fixture.binding)
            XCTAssertEqual(try fixture.store.schedulerAdmissions.activeCapacity(nodeID: fixture.nodeID), .zero)
            var historyCount = 0
            try fixture.store.schedulerAdmissions.visitReservationHistory(projectUUID: fixture.projectUUID) { _ in
                historyCount += 1
                return true
            }
            XCTAssertEqual(historyCount, 1)
        }
    }

    func testRestartIntentCanRetainTheEarlierAdmissionArtifact() throws {
        try withFixture { fixture in
            let restart = try fixture.addGroup(command: .restart)
            let authority = try XCTUnwrap(fixture.resolve())
            XCTAssertEqual(authority.entries.first?.planSHA256, restart.planSHA256)
            XCTAssertEqual(authority.entries.first?.reservation.lifecyclePlanDigest, fixture.initialPlan.planSHA256)
        }
    }

    func testRevokedSubjectCannotSupplyContinuedRunAuthority() throws {
        try withFixture { fixture in
            try fixture.store.controlIdentities.revoke(ControlIdentityRevocationRecord(
                revocationID: "revoke-owner", targetKind: .subject, targetIdentifier: "owner",
                reason: "test revocation", actorSubjectID: "owner", revokedAt: fixture.later
            ))
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .revokedSubject)
            }
        }
    }

    func testUnresolvedOrFailedLatestIntentHoldsInsteadOfResurrectingEarlierRun() throws {
        for status: OperationGroupStatus in [.active, .failed, .interrupted] {
            try withFixture { fixture in
                try fixture.addGroup(command: .down, status: status)
                XCTAssertThrowsError(try fixture.resolve()) {
                    XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .unresolvedIntent)
                }
            }
        }
    }

    func testMalformedOrStaleGroupFailsClosed() throws {
        try withFixture { fixture in
            try fixture.addGroup(command: .restart, intentOverride: "{}")
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .invalidHistory)
            }
        }
        try withFixture { fixture in
            try fixture.addGroup(command: .restart, manifestDigest: String(repeating: "f", count: 64))
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .staleProject)
            }
        }
    }

    func testGenerationMismatchCannotReuseOlderAdmission() throws {
        try withFixture { fixture in
            try fixture.addGroup(command: .update, generation: 2)
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .missingReservation)
            }
        }
    }

    func testMissingAdmissionGroupCannotPromoteAReleasedArtifactToRunAuthority() throws {
        try withFixture { fixture in
            try fixture.store.withConnection { connection in
                try connection.run("DELETE FROM operation_groups")
            }
            try fixture.addGroup(command: .restart)
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .missingReservation)
            }
        }
    }

    func testNoLocalHistoryIsDistinctFromAnExplicitlyPausedProject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        let manifest = try ManifestValidator.validated(LocalAuthorityFixture.manifestText)
        XCTAssertNil(try DaemonLocalLifecycleAuthority.resolve(
            store: store, manifest: manifest, manifestSHA256: String(repeating: "a", count: 64),
            projectID: "project-demo"
        ))
    }

    func testAuthorityStreamsMoreThan4096HistoricalGroupsAndRejectsLaterCorruption() throws {
        try withFixture { fixture in
            try fixture.duplicateLifecycleGroups(count: 4_100)
            var count = 0
            try fixture.store.operationGroups.visitProjectLifecycleHistory(projectID: fixture.projectID) { _ in count += 1 }
            XCTAssertEqual(count, 4_101)
            XCTAssertEqual(try XCTUnwrap(fixture.resolve()).entries.count, 1)
            try fixture.addGroup(command: .restart, intentOverride: "{}")
            XCTAssertThrowsError(try fixture.resolve()) {
                XCTAssertEqual($0 as? DaemonLocalLifecycleAuthorityError, .invalidHistory)
            }
        }
    }

    func testLaterDownWinsWhenWallClockMovesBackwards() throws {
        try withFixture { fixture in
            try fixture.addGroup(command: .down, timestamp: "2026-09-07T11:00:00Z")
            XCTAssertTrue(try XCTUnwrap(fixture.resolve()).entries.isEmpty)
        }
    }

    func testDaemonPolicyCallbackAcceptsCurrentOwnerWithUnchangedRequest() throws {
        try withFixture { fixture in
            try fixture.store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: fixture.timestamp)
            let request = try fixture.request()
            XCTAssertNoThrow(try LocalLifecycleDaemonReconciler.authorize(
                plan: fixture.initialPlan, request: request, subjectIDs: ["owner"], store: fixture.store
            ))
        }
    }

    func testDaemonPolicyCallbackRejectsRevokedAndExpiredSubjects() throws {
        for revoked in [true, false] {
            try withFixture { fixture in
                try fixture.store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: fixture.timestamp)
                let request = try fixture.request()
                if revoked {
                    try fixture.store.controlIdentities.revoke(ControlIdentityRevocationRecord(
                        revocationID: "revoke-owner", targetKind: .subject, targetIdentifier: "owner",
                        reason: "test revocation", actorSubjectID: "owner", revokedAt: fixture.later
                    ))
                } else {
                    _ = try fixture.store.controlIdentities.rotateCredential(
                        subjectID: "owner", expectedGeneration: 1, credentialID: nil, credentialPublicKeyBase64: nil,
                        credentialExpiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60)),
                        updatedAt: fixture.later
                    )
                }
                XCTAssertThrowsError(try LocalLifecycleDaemonReconciler.authorize(
                    plan: fixture.initialPlan, request: request, subjectIDs: ["owner"], store: fixture.store
                ))
            }
        }
    }

    func testDaemonPolicyCallbackRejectsRemovedRoleGrant() throws {
        try withFixture { fixture in
            try fixture.store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: fixture.timestamp)
            let request = try fixture.request()
            try fixture.store.controlIdentities.declare(ControlPeerIdentityRecord(
                subjectID: "backup", userID: 501, codeIdentity: CodeIdentity(
                    teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-authority-backup",
                    codeDirectoryHash: String(repeating: "b", count: 40), validationMode: .installedRequirement
                ), declaredBySubjectID: "owner", declaredAt: fixture.timestamp, updatedAt: fixture.timestamp
            ))
            _ = try fixture.store.rbac.createBinding(RBACBindingRecord(
                bindingID: "backup-owner", subjectID: "backup", roleID: "owner", scope: RBACScope(kind: .global),
                createdBySubjectID: "owner", createdAt: fixture.timestamp, updatedAt: fixture.timestamp
            ))
            try fixture.store.rbac.deleteBinding(id: "bootstrap-owner", expectedGeneration: 1)
            XCTAssertThrowsError(try LocalLifecycleDaemonReconciler.authorize(
                plan: fixture.initialPlan, request: request, subjectIDs: ["owner"], store: fixture.store
            ))
        }
    }

    func testDaemonPolicyCallbackRejectsCurrentAdmissionDenial() throws {
        try withFixture { fixture in
            try fixture.store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: fixture.timestamp)
            let request = try fixture.request()
            let document: ControlPlaneJSONValue = .object([
                "schemaVersion": .integer(1), "operations": .array([.string("up")]),
                "conditions": .array([]), "mutations": .array([]), "validations": .array([.object([
                    "kind": .string("required"), "fieldPath": .string("/approvedLabel"),
                    "reasonCode": .string("admission.approval-required")
                ])])
            ])
            _ = try fixture.store.admission.createPolicy(AdmissionPolicyRecord(
                policyID: "require-approval", version: 1, sourceKind: .builtIn, stage: .builtInValidation,
                failurePolicy: .deny, advisory: false, mutating: false, document: document,
                documentSHA256: AdmissionPolicyRecord.digest(document), createdBySubjectID: "owner",
                createdAt: fixture.timestamp, updatedAt: fixture.timestamp
            ))
            XCTAssertThrowsError(try LocalLifecycleDaemonReconciler.authorize(
                plan: fixture.initialPlan, request: request, subjectIDs: ["owner"], store: fixture.store
            ))
        }
    }

    func testPolicyBearingManifestKeepsSourceAndEffectiveDigestsDistinct() throws {
        let source = LocalAuthorityFixture.manifestText.replacingOccurrences(
            of: "project: demo", with: "project: demo\nimagePolicy: require-digest"
        ).replacingOccurrences(
            of: "ghcr.io/example/api:latest", with: "ghcr.io/example/api@sha256:" + String(repeating: "a", count: 64)
        ) + """

        imageSBOM:
          version: 1
          requirement: required
          formats: [spdx-json]
        """
        try withFixture(manifestText: source) { fixture in
            try fixture.store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: fixture.timestamp)
            let authority = try XCTUnwrap(fixture.resolve())
            XCTAssertEqual(authority.sourceManifestSHA256, fixture.sourceDigest)
            XCTAssertEqual(authority.manifestSHA256, fixture.digest)
            XCTAssertNotEqual(authority.sourceManifestSHA256, authority.manifestSHA256)
            XCTAssertEqual(try UnattendedLifecycleReconciler().lifecycleManifestSHA256(
                text: source, manifest: fixture.manifest
            ), fixture.digest)
            XCTAssertEqual(try LocalLifecycleDaemonReconciler().lifecycleManifestSHA256(
                text: source, manifest: fixture.manifest
            ), fixture.digest)
            XCTAssertThrowsError(try PolicyFreeDigestTestDriver().lifecycleManifestSHA256(
                text: source, manifest: fixture.manifest
            ))
            let request = try fixture.request()
            XCTAssertEqual(request.manifestSHA256, authority.sourceManifestSHA256)
            XCTAssertNoThrow(try LocalLifecycleDaemonReconciler.authorize(
                plan: fixture.initialPlan, request: request, subjectIDs: ["owner"], store: fixture.store
            ))
            try authority.revalidate(
                store: fixture.store, manifest: fixture.manifest, projectID: fixture.projectID,
                lifecycleManifestSHA256: fixture.digest
            )
            XCTAssertThrowsError(try authority.revalidate(
                store: fixture.store, manifest: fixture.manifest, projectID: fixture.projectID,
                lifecycleManifestSHA256: fixture.sourceDigest
            ))
        }
    }

    private func withFixture(
        manifestText: String = LocalAuthorityFixture.manifestText,
        _ body: (LocalAuthorityFixture) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(LocalAuthorityFixture(directory: directory, manifestText: manifestText))
    }
}

private final class LocalAuthorityFixture {
    static let manifestText = """
    version: 3
    project: demo
    services:
      api:
        image: ghcr.io/example/api:latest
        resources:
          requests:
            cpus: 1
            memory: 512MiB
          limits:
            cpus: 1
            memory: 512MiB
    """
    let projectID = "project-demo"
    let projectUUID = "11111111-1111-4111-8111-111111111111"
    let resourceUUID = "22222222-2222-4222-8222-222222222222"
    let fence = "33333333-3333-4333-8333-333333333333"
    let nodeID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let timestamp = "2026-09-07T12:00:00Z"
    let later = "2026-09-07T12:01:00Z"
    let store: SQLiteStateStore
    let manifest: HostwrightManifest
    let sourceText: String
    let sourceDigest: String
    let digest: String
    let binding: SchedulerRuntimeOwnershipBinding
    private(set) var initialPlan: LifecyclePlan!
    private var sequence = 0

    init(directory: URL, manifestText: String) throws {
        store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
        try store.migrate()
        sourceText = manifestText
        manifest = try ManifestValidator.validated(manifestText)
        sourceDigest = SHA256.hash(data: Data(manifestText.utf8)).map { String(format: "%02x", $0) }.joined()
        digest = try HostwrightLifecycleManifestDigest.sha256(text: manifestText, manifest: manifest)
        let identifier = RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier
        binding = try SchedulerRuntimeOwnershipBinding(
            resourceIdentifier: identifier, resourceType: "container", resourceUUID: resourceUUID,
            resourceGeneration: 1, projectUUID: projectUUID, projectName: "demo", projectGeneration: 1,
            serviceName: "api", instanceName: nil, identityVersion: RuntimeManagedResourceIdentity.currentVersion,
            providerID: .appleContainerCLI, providerAPIVersion: HostwrightContractVersions.runtimeProviderAPI,
            providerVersion: "1.1.0", providerGeneration: 1, fencingToken: fence
        )
        try store.desiredStates.saveManifestSnapshot(
            projectID: projectID, manifestPath: "hostwright.yaml", manifestHash: digest,
            desiredGeneration: 1, manifest: manifest, timestamp: timestamp,
            mutationProvider: RuntimeProviderID.appleContainerCLI.rawValue, projectResourceUUID: projectUUID
        )
        try store.controlIdentities.bootstrap(ControlPeerIdentityRecord(
            subjectID: "owner", userID: 501,
            codeIdentity: CodeIdentity(
                teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-authority-test",
                codeDirectoryHash: String(repeating: "a", count: 40), validationMode: .installedRequirement
            ), declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp
        ))
        try store.ownership.upsert(OwnershipRecord(
            id: UUID().uuidString.lowercased(), resourceIdentifier: identifier, resourceType: "container",
            projectID: projectID, serviceName: "api", runtimeAdapter: RuntimeProviderID.appleContainerCLI.rawValue,
            createdAt: timestamp, observedAt: timestamp, cleanupEligible: true, metadataJSONRedacted: "{}",
            identityVersion: binding.identityVersion, resourceUUID: resourceUUID, resourceGeneration: 1,
            projectResourceUUID: projectUUID, projectGeneration: 1, providerGeneration: 1, fencingToken: fence
        ))
        initialPlan = try addGroup(command: .up)
        let resources = try ResourceVector(["cpu": 1, "memory": 536_870_912])
        let capacity = try store.schedulerAdmissions.recordNodeCapacity(snapshot: SchedulerNodeCapacitySnapshot(
            nodeID: nodeID, capacity: ResourceVector(["cpu": 4, "memory": 4_294_967_296]),
            generation: 1, observedAt: timestamp
        ))
        let workload = try SchedulerWorkload(
            requirements: WorkloadPlacementRequirements(workloadID: binding.lifecycleWorkloadID, request: resources),
            priority: 0, subjectID: "owner", projectID: projectUUID
        )
        let decision = try SchedulerEngine().plan(SchedulerEngineInput(
            pendingWorkloads: [workload], nodes: [SchedulerNode(snapshot: NodePlacementSnapshot(
                nodeID: nodeID, capacity: capacity.capacity, allocation: .zero, architecture: "arm64",
                runtime: "linux-vm", provider: RuntimeProviderID.appleContainerCLI.rawValue
            ))]
        ))
        try store.schedulerAdmissions.recordDecisionArtifact(
            decision: decision, workloadBindings: [SchedulerDecisionWorkloadBinding(
                workloadID: workload.workloadID, nodeID: nodeID, resources: resources,
                capacityDigest: capacity.capacityDigest, capacityGeneration: 1, ownerSubjectID: "owner",
                projectUUID: projectUUID, runtimeOwnership: binding
            )], projectUUID: projectUUID, configDigest: digest, profileDigest: digest,
            lifecyclePlanDigest: initialPlan.planSHA256, createdAt: timestamp, updatedAt: timestamp
        )
        let reservation = try store.schedulerAdmissions.reserve(
            binding: SchedulerAdmissionBinding(
                decisionID: decision.decisionID, workloadID: workload.workloadID, nodeID: nodeID,
                resources: resources, nodeCapacityDigest: capacity.capacityDigest, nodeCapacityGeneration: 1,
                inputDigest: decision.inputDigest, configDigest: digest, profileDigest: digest,
                lifecyclePlanDigest: initialPlan.planSHA256, ownerSubjectID: "owner", projectUUID: projectUUID,
                createdAt: timestamp, expiresAt: "2026-09-07T12:05:00Z"
            ), authority: SchedulerAdmissionAuthority(
                nodeCapacityDigest: capacity.capacityDigest, nodeCapacityGeneration: 1,
                inputDigest: decision.inputDigest, configDigest: digest, profileDigest: digest,
                lifecyclePlanDigest: initialPlan.planSHA256, expectedNodeEpoch: 1
            )
        )
        try store.schedulerAdmissions.commit(
            reservationID: reservation.reservationID, expectedToken: reservation.fencingToken, updatedAt: timestamp
        )
    }

    func resolve() throws -> DaemonLocalLifecycleAuthority? {
        try DaemonLocalLifecycleAuthority.resolve(
            store: store, manifest: manifest, manifestSHA256: sourceDigest, projectID: projectID,
            lifecycleManifestSHA256: digest
        )
    }

    func release() throws {
        let reservation = try XCTUnwrap(store.schedulerAdmissions.activeReservation(
            workloadID: binding.lifecycleWorkloadID, projectUUID: projectUUID
        ))
        try store.schedulerAdmissions.release(
            reservationID: reservation.reservationID, expectedToken: reservation.fencingToken,
            evidence: .verifiedRuntimeAbsence(evidenceDigest: digest, verifiedAt: later)
        )
    }

    func duplicateLifecycleGroups(count: Int) throws {
        let table = "operation_groups"
        try store.withConnection { connection in
            let columns = try connection.query("PRAGMA table_info(\(table))").compactMap { $0[1] }
            let expressions = columns.map { column -> String in
                switch column {
                case "id": return "printf('99999999-0000-4000-8000-%012d', n)"
                case "fencing_token": return "printf('77777777-0000-4000-8000-%012d', n)"
                case "operation_id": return "printf('88888888-0000-4000-8000-%012d', n)"
                case "group_idempotency_key": return "'historical-group-' || n"
                default: return "source.\(column)"
                }
            }
            try connection.run("""
                WITH RECURSIVE sequence(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM sequence WHERE n < ?)
                INSERT INTO \(table) (\(columns.joined(separator: ",")))
                SELECT \(expressions.joined(separator: ","))
                FROM (SELECT * FROM \(table) LIMIT 1) AS source CROSS JOIN sequence
                """, bindings: [.int(count)])
        }
    }

    func request() throws -> DaemonReconciliationRequest {
        let local = try XCTUnwrap(resolve())
        let path = URL(fileURLWithPath: store.path).deletingLastPathComponent()
            .appendingPathComponent("hostwright.yaml").path
        let target = try DaemonConfigurationTarget(
            kind: .manifest, path: path, contentSHA256: sourceDigest, byteCount: sourceText.utf8.count,
            device: 1, inode: 1
        )
        return try DaemonReconciliationRequest(
            manifestPath: path, manifestSHA256: sourceDigest,
            configurationSetSHA256: DaemonConfigurationSetDigest.sha256([target]), configurationTargets: [target],
            stateDatabasePath: store.path, projectID: projectID, maximumParallelism: 1,
            selectedServiceNames: ["api"], schedulerAuthorityBinding: DaemonSchedulerAuthorityBinding(localLifecycleAuthority: local)
        )
    }

    @discardableResult
    func addGroup(
        command: LifecycleCommand, status: OperationGroupStatus = .succeeded,
        generation: Int = 1, intentOverride: String? = nil, manifestDigest: String? = nil,
        timestamp: String? = nil
    ) throws -> LifecyclePlan {
        sequence += 1
        let plan = try LifecyclePlan(
            command: command, projectID: projectID, projectName: "demo", projectResourceUUID: projectUUID,
            projectGeneration: 1, providerID: .appleContainerCLI, providerGeneration: 1,
            manifestSHA256: manifestDigest ?? digest, observationSHA256: digest, capabilitySHA256: digest,
            parallelism: 1, nodes: [LifecyclePlanNode(
                key: "api.verify", action: .verify, serviceName: "demo/api",
                resourceIdentifier: binding.resourceIdentifier, resourceUUID: resourceUUID,
                resourceGeneration: generation, fencingToken: fence,
                desiredSpecificationJSONRedacted: try LifecycleRevisionCodec.redactedDesiredJSON(
                    for: ManifestRuntimeMapper.map(
                        manifest, projectResourceUUID: projectUUID, schedulerAdmissionValidated: true
                    ).desiredState.services[0]
                )
            )]
        )
        let groupID = UUID().uuidString.lowercased()
        let time = timestamp ?? String(format: "2026-09-07T12:00:%02dZ", sequence)
        let group = OperationGroupRecord(
            id: groupID, operationID: UUID().uuidString.lowercased(), groupKind: "lifecycle-v1",
            projectID: projectID, serviceName: nil, plannedActionType: command.rawValue, status: .active,
            groupIdempotencyKey: "group-\(sequence)", planHash: plan.planSHA256, checkpoint: "intent-persisted",
            lockOwner: "authority-test", lockExpiresAt: "2026-09-07T13:00:00Z", rollbackAvailable: false,
            manualRecoveryHintRedacted: "", createdAt: time, updatedAt: time,
            metadataJSONRedacted: "{}", fencingToken: UUID().uuidString.lowercased(),
            intentJSONRedacted: try intentOverride ?? LifecyclePersistedIntentCodec.encode(plan)
        )
        _ = try store.operationGroups.acquire(group, currentTimestamp: time)
        if status != .active {
            try store.operationGroups.finish(
                groupID: groupID, status: status, checkpoint: "completed", manualRecoveryHintRedacted: "",
                updatedAt: time, metadataJSONRedacted: "{}"
            )
        }
        return plan
    }
}

private struct PolicyFreeDigestTestDriver: DaemonReconciliationDriving {
    func reconcile(request: DaemonReconciliationRequest) async throws -> DaemonReconciliationResult {
        throw DaemonLocalLifecycleAuthorityError.missingIntent
    }
}
