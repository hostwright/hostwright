import Foundation
import CryptoKit
import XCTest

@testable import HostwrightCore
@testable import HostwrightControlPlane
@testable import HostwrightDaemon
@testable import HostwrightScheduler
@testable import HostwrightState
@testable import HostwrightRuntime

final class SchedulerStartupRecoveryTests: XCTestCase {
  private let projectUUID = "00000000-0000-0000-0000-0000000000b1"
  private let nodeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
  private let workloadID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b3")!
  private let createdAt = "2026-08-05T12:00:00Z"
  private let recoveredAt = "2026-08-05T12:01:00Z"

  func testStartupRecoveryCommitsOnlyVerifiedPresentTargetAndReplays() throws {
    try withPendingReservation { repository, reservation in
      let coordinator = makeCoordinator(repository: repository) { _ in
        try SchedulerRuntimeObservation(
          state: .present,
          evidenceDigest: String(repeating: "a", count: 64)
        )
      }
      let first = try coordinator.recover()
      XCTAssertEqual(first.examinedReservations, 1)
      XCTAssertEqual(first.committedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .committed
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), try ResourceVector(["cpu": 1]))

      let replay = try coordinator.recover()
      XCTAssertEqual(replay.examinedReservations, 1)
      XCTAssertEqual(replay.retainedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .committed
      )
    }
  }

  func testStartupRecoveryReleasesOnlyVerifiedAbsentTargetAndIsIdempotent() throws {
    try withPendingReservation { repository, reservation in
      let coordinator = makeCoordinator(repository: repository) { _ in
        try SchedulerRuntimeObservation(
          state: .absent,
          evidenceDigest: String(repeating: "b", count: 64)
        )
      }
      let first = try coordinator.recover()
      XCTAssertEqual(first.releasedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .released
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), .zero)

      let replay = try coordinator.recover()
      XCTAssertEqual(replay.examinedReservations, 0)
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), .zero)
    }
  }

  func testStartupRecoveryReleasesCommittedWorkloadThatStoppedWhileDaemonWasDown() throws {
    try withPendingReservation { repository, reservation in
      try repository.commit(
        reservationID: reservation.reservationID, expectedToken: reservation.fencingToken,
        updatedAt: createdAt
      )
      let report = try makeCoordinator(repository: repository) { _ in
        try SchedulerRuntimeObservation(state: .absent, evidenceDigest: String(repeating: "f", count: 64))
      }.recover()
      XCTAssertEqual(report.releasedReservations, 1)
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), .zero)
      XCTAssertEqual(try repository.reservation(id: reservation.reservationID)?.status, .released)
    }
  }

  func testStartupRecoveryRetainsUnknownRuntimeStateAndNeverUsesExpiry() throws {
    try withPendingReservation { repository, reservation in
      let coordinator = makeCoordinator(repository: repository) { _ in
        try SchedulerRuntimeObservation(
          state: .unknown,
          evidenceDigest: String(repeating: "c", count: 64)
        )
      }
      let report = try coordinator.recover()
      XCTAssertEqual(report.retainedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .pending
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), try ResourceVector(["cpu": 1]))
    }
  }

  func testRuntimeInventoryObserverRequiresCompleteAuthoritativeSnapshot() throws {
    try withPendingReservation { _, reservation in
      let ownership = try runtimeOwnership(for: reservation)
      let boundReservation = reservation.hydrated(with: ownership)

      let absentInventory = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        includeContainer: false
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: absentInventory
        ).state,
        .absent
      )

      let unavailableInventory = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        machineState: .unavailable,
        machineServices: [
          RuntimeInventoryService(
            identifier: "runtime-service",
            state: .unavailable,
            required: true
          )
        ],
        includeContainer: false
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: unavailableInventory
        ).state,
        .unknown
      )

      let incompleteInventory = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        machineServices: [],
        includeContainer: false,
        authority: .incomplete
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: incompleteInventory
        ).state,
        .unknown
      )
    }
  }

  func testRuntimeInventoryObserverRetainsOnStaleOrForeignOwnershipTuple() throws {
    try withPendingReservation { _, reservation in
      let ownership = try runtimeOwnership(for: reservation)
      let boundReservation = reservation.hydrated(with: ownership)

      let staleGeneration = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        resourceGeneration: 2
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: staleGeneration
        ).state,
        .unknown
      )

      let foreignProvider = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        providerID: .appleContainerization
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: foreignProvider
        ).state,
        .unknown
      )

      let foreignResource = try runtimeInventory(
        reservation: reservation,
        ownership: ownership,
        resourceUUID: HostwrightResourceUUID.legacy(
          kind: "foreign-resource",
          identifier: reservation.workloadID.uuidString
        )
      )
      XCTAssertEqual(
        try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: boundReservation,
          inventory: foreignResource
        ).state,
        .unknown
      )
    }
  }

  func testStartupRecoveryRetainsCapacityWhenInventoryIsUnavailableOrThrows() throws {
    try withPendingReservation { repository, reservation in
      let unavailable = try runtimeInventory(
        reservation: reservation,
        ownership: try runtimeOwnership(for: reservation),
        machineState: .unavailable,
        machineServices: [
          RuntimeInventoryService(
            identifier: "runtime-service",
            state: .unavailable,
            required: true
          )
        ],
        includeContainer: false
      )
      let coordinator = makeCoordinator(repository: repository) { reservation in
        let observation = try HostwrightDaemonControlService.schedulerRuntimeObservation(
          reservation: reservation,
          inventory: unavailable
        )
        return observation
      }
      let unavailableReport = try coordinator.recover()
      XCTAssertEqual(unavailableReport.retainedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .pending
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), try ResourceVector(["cpu": 1]))
    }

    try withPendingReservation { repository, reservation in
      let coordinator = makeCoordinator(repository: repository) { _ in
        throw SchedulerAdmissionError.stateInvariant("runtime-inventory-unavailable")
      }
      let errorReport = try coordinator.recover()
      XCTAssertEqual(errorReport.retainedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .pending
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), try ResourceVector(["cpu": 1]))
    }
  }

  func testStartupRecoveryRetainsAbsentObservationAfterNodeEpochBump() throws {
    try withPendingReservation { repository, reservation in
      let current = try repository.fencingState(nodeID: nodeID)
      _ = try repository.recoverNode(
        evidence: try SchedulerNodeRecoveryEvidence(
          nodeID: nodeID,
          expectedNodeEpoch: current.nodeEpoch,
          newNodeEpoch: current.nodeEpoch + 1,
          evidenceDigest: String(repeating: "d", count: 64),
          verifiedAt: recoveredAt
        )
      )
      let coordinator = makeCoordinator(repository: repository) { _ in
        try SchedulerRuntimeObservation(
          state: .absent,
          evidenceDigest: String(repeating: "e", count: 64)
        )
      }
      let report = try coordinator.recover()
      XCTAssertEqual(report.retainedReservations, 1)
      XCTAssertEqual(
        try repository.reservation(id: reservation.reservationID)?.status,
        .pending
      )
      XCTAssertEqual(try repository.activeCapacity(nodeID: nodeID), try ResourceVector(["cpu": 1]))
    }
  }

  private func makeCoordinator(
    repository: SchedulerAdmissionRepository,
    observe: @escaping SchedulerStartupRecoveryCoordinator.RuntimeObservationProvider
  ) -> SchedulerStartupRecoveryCoordinator {
    let recoveredAt = self.recoveredAt
    return SchedulerStartupRecoveryCoordinator(
      repository: repository,
      observe: observe,
      now: { recoveredAt }
    )
  }

  private func runtimeOwnership(
    for reservation: SchedulerReservationRecord
  ) throws -> SchedulerRuntimeOwnershipBinding {
    let identity = RuntimeServiceIdentity(
      projectName: "startup-recovery-project",
      serviceName: "startup-recovery-service"
    )
    return try SchedulerRuntimeOwnershipBinding(
      resourceIdentifier: identity.managedResourceIdentifier,
      resourceType: "container",
      resourceUUID: reservation.workloadID.uuidString.lowercased(),
      resourceGeneration: 1,
      projectUUID: projectUUID,
      projectName: identity.projectName,
      projectGeneration: 1,
      serviceName: identity.serviceName,
      instanceName: identity.instanceName,
      identityVersion: RuntimeManagedResourceIdentity.currentVersion,
      providerID: .appleContainerCLI,
      providerAPIVersion: HostwrightContractVersions.runtimeProviderAPI,
      providerVersion: "1.1.0",
      providerGeneration: 1,
      fencingToken: HostwrightResourceUUID.legacy(
        kind: "ownership-fence",
        identifier: reservation.workloadID.uuidString
      )
    )
  }

  private func runtimeInventory(
    reservation: SchedulerReservationRecord,
    ownership: SchedulerRuntimeOwnershipBinding,
    machineState: RuntimeInventoryMachineState = .running,
    machineServices: [RuntimeInventoryService]? = nil,
    includeContainer: Bool = true,
    authority: RuntimeInventoryAuthority = .appleContainerCLIRuntimeList,
    resourceGeneration: Int = 1,
    providerID: RuntimeProviderID = .appleContainerCLI,
    resourceUUID: String? = nil,
    lifecycle: RuntimeInventoryLifecycleState = .running
  ) throws -> RuntimeInventory {
    let identity = RuntimeServiceIdentity(
      projectName: ownership.projectName,
      serviceName: ownership.serviceName,
      instanceName: ownership.instanceName
    )
    let lifecycleFence = schedulerRuntimeFenceToken(for: reservation)
    let resolvedResourceUUID = resourceUUID ?? ownership.resourceUUID
    let context = RuntimeMutationContext(
      providerID: providerID,
      capabilitySHA256: String(repeating: "a", count: 64),
      operationID: "scheduler-startup-recovery-observation",
      resourceUUID: resolvedResourceUUID,
      resourceGeneration: resourceGeneration,
      projectResourceUUID: ownership.projectUUID,
      projectGeneration: 1,
      providerGeneration: 1,
      fencingToken: lifecycleFence
    )
    let labels = try RuntimeManagedResourceIdentity.labels(
      for: identity,
      resourceIdentifier: ownership.resourceIdentifier,
      context: context
    ).map { RuntimeInventoryLabel(key: $0.key, value: $0.value) }
    let evidence = RuntimeInventoryOwnershipEvidence(
      resourceUUID: resolvedResourceUUID,
      projectUUID: ownership.projectUUID,
      resourceGeneration: resourceGeneration,
      projectGeneration: 1,
      providerID: providerID,
      providerGeneration: 1,
      fencingToken: lifecycleFence
    )
    let containers: [RuntimeInventoryContainer] = includeContainer ? [
      RuntimeInventoryContainer(
        runtimeID: "runtime-(reservation.workloadID.uuidString.lowercased())",
        name: ownership.resourceIdentifier,
        imageReference: "registry.example/startup-recovery:1.1.0",
        lifecycle: lifecycle,
        health: RuntimeInventoryHealth(
          availability: .available,
          state: .healthy
        ),
        labels: labels,
        ownership: evidence,
        initConfiguration: RuntimeInventoryInitConfiguration(
          executable: "/bin/true",
          arguments: [],
          environment: []
        ),
        ports: [],
        mounts: [],
        networks: [],
        services: []
      )
    ] : []
    let machine = RuntimeInventoryMachine(
      state: machineState,
      operatingSystem: "macOS",
      architecture: "arm64",
      runtimeVersion: ownership.providerVersion,
      services: machineServices ?? [
        RuntimeInventoryService(
          identifier: "runtime-service",
          state: .running,
          required: true
        )
      ]
    )
    let inventory = try RuntimeInventoryBuilder.build(
      machine: machine,
      containers: containers,
      images: [],
      networks: [],
      volumes: []
    )
    guard authority.isAuthoritative else { return inventory }
    return try RuntimeInventoryBuilder.markRuntimeListAuthoritative(
      inventory,
      source: authority
    )
  }

  private func schedulerRuntimeFenceToken(
    for reservation: SchedulerReservationRecord
  ) -> String {
    let operationKey = SHA256.hash(
      data: Data([
        "scheduler-up",
        reservation.decisionID.uuidString.lowercased(),
        reservation.reservationID.uuidString.lowercased(),
        reservation.fencingToken.stableKey,
      ].joined(separator: "|").utf8)
    )
    .map { String(format: "%02x", $0) }
    .joined()
    return HostwrightResourceUUID.legacy(
      kind: "lifecycle-fencing",
      identifier: operationKey
    )
  }

  private func withPendingReservation(
    _ body: (SchedulerAdmissionRepository, SchedulerReservationRecord) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-scheduler-startup-recovery-(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = SQLiteStateStore(path: directory.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "startup-recovery-owner",
        userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q",
          signingIdentifier: "hostwright",
          codeDirectoryHash: String(repeating: "a", count: 40),
          validationMode: .installedRequirement
        ),
        declaredBySubjectID: "startup-recovery-owner",
        declaredAt: createdAt,
        updatedAt: createdAt
      )
    )
    try store.withValidatedConnection { connection in
      try connection.run(
        """
        INSERT INTO projects (
          id, name, manifest_path, manifest_hash, created_at, updated_at,
          resource_uuid, manifest_version, mutation_provider, provider_generation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
          .text("startup-recovery-project"), .text("startup-recovery-project"), .null,
          .text(String(repeating: "f", count: 64)), .text(createdAt), .text(createdAt),
          .text(projectUUID), .int(1), .null, .int(0),
        ]
      )
    }
    let repository = SchedulerAdmissionRepository(store: store)
    let capacity = try ResourceVector(["cpu": 2])
    let snapshot = try SchedulerNodeCapacitySnapshot(
      nodeID: nodeID,
      capacity: capacity,
      generation: 1,
      observedAt: createdAt
    )
    _ = try repository.recordNodeCapacity(snapshot: snapshot)
    _ = try repository.recordHostPressure(
      record: try SchedulerHostPressureRecord(
        nodeID: nodeID,
        posture: SchedulerHostPosture(pressure: .nominal, energy: .balanced),
        generation: 1,
        observedAt: createdAt,
        evidenceDigest: String(repeating: "a", count: 64),
        policyState: try SchedulerHostPressurePolicyState(
          version: SchedulerHostPressurePolicyState.currentVersion,
          reasonCodes: [.allowed],
          nextHysteresisState: try SchedulerHostPressureHysteresisState(
            posture: .allowed,
            consecutiveClearObservations: 0,
            version: SchedulerHostPressurePolicyState.currentVersion
          )
        )
      )
    )
    let workload = try SchedulerWorkload(
      requirements: try WorkloadPlacementRequirements(
        workloadID: workloadID,
        request: try ResourceVector(["cpu": 1])
      ),
      priority: 1,
      subjectID: "startup-recovery-owner",
      projectID: projectUUID
    )
    let node = try SchedulerNode(
      snapshot: try NodePlacementSnapshot(
        nodeID: nodeID,
        capacity: capacity,
        allocation: .zero,
        architecture: "arm64",
        runtime: "linux-vm",
        provider: "provider"
      )
    )
    let decision = try SchedulerEngine().plan(
      try SchedulerEngineInput(pendingWorkloads: [workload], nodes: [node])
    )
    let decisionWorkload = try XCTUnwrap(decision.workloadDecisions.first)
    let binding = try SchedulerDecisionWorkloadBinding(
      workloadID: workloadID,
      nodeID: try XCTUnwrap(decisionWorkload.chosenNodeID),
      resources: workload.request,
      capacityDigest: snapshot.capacityDigest,
      capacityGeneration: snapshot.generation,
      ownerSubjectID: workload.subjectID,
      projectUUID: projectUUID
    )
    _ = try repository.recordDecisionArtifact(
      decision: decision,
      workloadBindings: [binding],
      projectUUID: projectUUID,
      configDigest: String(repeating: "1", count: 64),
      profileDigest: String(repeating: "2", count: 64),
      lifecyclePlanDigest: String(repeating: "3", count: 64),
      createdAt: createdAt,
      updatedAt: createdAt
    )
    let admissionBinding = try SchedulerAdmissionBinding(
      decisionID: decision.decisionID,
      workloadID: workloadID,
      nodeID: nodeID,
      resources: workload.request,
      nodeCapacityDigest: snapshot.capacityDigest,
      nodeCapacityGeneration: snapshot.generation,
      inputDigest: decision.inputDigest,
      configDigest: String(repeating: "1", count: 64),
      profileDigest: String(repeating: "2", count: 64),
      lifecyclePlanDigest: String(repeating: "3", count: 64),
      ownerSubjectID: workload.subjectID,
      projectUUID: projectUUID,
      createdAt: createdAt,
      expiresAt: "2026-08-05T12:04:00Z"
    )
    let reservation = try repository.reserve(
      binding: admissionBinding,
      authority: try SchedulerAdmissionAuthority(
        nodeCapacityDigest: snapshot.capacityDigest,
        nodeCapacityGeneration: snapshot.generation,
        inputDigest: decision.inputDigest,
        configDigest: String(repeating: "1", count: 64),
        profileDigest: String(repeating: "2", count: 64),
        lifecyclePlanDigest: String(repeating: "3", count: 64),
        expectedNodeEpoch: 1
      )
    )
    try body(repository, reservation)
  }
}
