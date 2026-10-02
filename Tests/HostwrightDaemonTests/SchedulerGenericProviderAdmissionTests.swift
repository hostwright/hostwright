import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightRuntime
import HostwrightScheduler
import HostwrightState
import XCTest
@testable import HostwrightDaemon

final class SchedulerGenericProviderAdmissionTests: XCTestCase {
  private let projectUUID = "00000000-0000-0000-0000-0000000000a1"

  func testActualSDKDaemonRejectsRawAndSpoofedGenericPlanBeforeStateOrRuntimeEffects() throws {
    for claimedProvider in [RuntimeProviderID.appleContainerization, .appleContainerCLI] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
      let repository = store.schedulerAdmissions
      let metadata = RuntimeAdapterMetadata(
        providerID: .appleContainerization, adapterName: "ContainerizationRuntimeAdapter",
        adapterVersion: "0.0.2-dev", runtimeName: "Containerization", runtimeVersion: "0.35.0",
        supportsMutation: true, capabilities: [.readOnlyObservation]
      )
      let authority = HostwrightDaemonControlService.makeSchedulerAuthorityProvider(
        store: store, repository: repository, configPath: root.appendingPathComponent("hostwright.yaml").path,
        pressureCoordinator: SchedulerPressureAuthorityCoordinator(
          probe: SchedulerMacOSHostPressureProbe(), repository: repository, clock: { Date() }
        ), runtimeMetadata: metadata, runtimeVersion: { "0.35.0" }
      )
      let input = try rawInput(provider: claimedProvider)
      let decision = try SchedulerEngine().plan(input)
      XCTAssertEqual(decision.workloadDecisions.first?.outcome, .placed)
      XCTAssertEqual(decision.workloadDecisions.first?.capacityExplanation?.chargedCapacity,
                     try ResourceVector(["cpu": 1, "memory": 512 * 1_024 * 1_024]))
      XCTAssertThrowsError(try authority(projectUUID, decision, input)) { error in
        XCTAssertEqual(error as? SchedulerControlOperationError, .authorityUnavailable)
      }
      XCTAssertThrowsError(try authority(projectUUID, decision, nil)) { error in
        XCTAssertEqual(error as? SchedulerControlOperationError, .authorityUnavailable)
      }
      let response = try planResponse(
        input: input, repository: repository, authority: authority,
        pressureRefresher: HostwrightDaemonControlService.makeSchedulerPressureRefresher(
          pressureCoordinator: SchedulerPressureAuthorityCoordinator(
            probe: SchedulerMacOSHostPressureProbe(), repository: repository, clock: { Date() }
          ), runtimeMetadata: metadata, runtimeVersion: {
            XCTFail("Unsupported SDK generic planning must not probe the runtime.")
            return "0.35.0"
          }
        )
      )
      XCTAssertEqual(response.status, .rejected)
      XCTAssertEqual(response.error?.code, "schedulerAuthorityUnavailable")
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
  }

  func testGenericAuthorityRejectsMissingRuntimeBeforeStateEffects() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    let repository = store.schedulerAdmissions
    let metadata = RuntimeAdapterMetadata(
      providerID: .appleContainerCLI, adapterName: "AppleContainerCLIAdapter",
      adapterVersion: "0.0.2-dev", runtimeName: "Apple container CLI",
      runtimeVersion: nil, supportsMutation: true, capabilities: [.readOnlyObservation]
    )
    let adapter = AppleContainerCLIAdapter(
      executableResolver: RuntimeExecutableResolver(path: root.path)
    )
    let runtimeVersion: @Sendable () throws -> String = {
      try HostwrightDaemonControlService.waitForSchedulerRuntime {
        try await adapter.runtimeVersion()
      }
    }
    let authority = HostwrightDaemonControlService.makeSchedulerAuthorityProvider(
      store: store, repository: repository, configPath: root.appendingPathComponent("hostwright.yaml").path,
      pressureCoordinator: SchedulerPressureAuthorityCoordinator(
        probe: SchedulerMacOSHostPressureProbe(), repository: repository, clock: { Date() }
      ), runtimeMetadata: metadata, runtimeVersion: runtimeVersion
    )
    let input = try rawInput(provider: .appleContainerCLI)
    let decision = try SchedulerEngine().plan(input)
    for suppliedInput in [input, nil] as [SchedulerEngineInput?] {
      XCTAssertThrowsError(try authority(projectUUID, decision, suppliedInput)) { error in
        XCTAssertEqual(
          error as? RuntimeAdapterError,
          .runtimeUnavailable("Apple container CLI was not found on PATH.")
        )
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try store.migrate()
    let node = try XCTUnwrap(input.nodes.first)
    _ = try repository.recordNodeCapacity(snapshot: SchedulerNodeCapacitySnapshot(
      nodeID: node.nodeID, capacity: node.capacity, generation: 1,
      observedAt: "2026-10-02T23:45:00Z"
    ))
    XCTAssertNil(try repository.hostPressure(nodeID: node.nodeID))
    let response = try planResponse(
      input: input, repository: repository, authority: authority,
      pressureRefresher: HostwrightDaemonControlService.makeSchedulerPressureRefresher(
        pressureCoordinator: SchedulerPressureAuthorityCoordinator(
          probe: SchedulerMacOSHostPressureProbe(), repository: repository, clock: { Date() }
        ), runtimeMetadata: metadata, runtimeVersion: runtimeVersion
      )
    )
    XCTAssertEqual(response.status, .rejected)
    XCTAssertEqual(response.error?.code, "schedulerInvalidRequest")
    XCTAssertNil(try repository.hostPressure(nodeID: node.nodeID))
  }

  func testGenericApplyRejectsMissingOrSDKCanonicalOwnershipAndPreservesApple() throws {
    let apple = try ownership(provider: .appleContainerCLI)
    let sdk = try ownership(provider: .appleContainerization)
    XCTAssertNoThrow(try HostwrightDaemonControlService.validateGenericSchedulerProvider(.appleContainerCLI))
    XCTAssertNoThrow(try HostwrightDaemonControlService.validateGenericSchedulerRuntimeOwnership(
      apple, actualProviderID: .appleContainerCLI
    ))
    for canonical in [nil, sdk] as [SchedulerRuntimeOwnershipBinding?] {
      XCTAssertThrowsError(try HostwrightDaemonControlService.validateGenericSchedulerRuntimeOwnership(
        canonical, actualProviderID: .appleContainerCLI
      )) { error in
        XCTAssertEqual(error as? SchedulerControlOperationError, .authorityUnavailable)
      }
    }
    XCTAssertThrowsError(try HostwrightDaemonControlService.validateGenericSchedulerRuntimeOwnership(
      apple, actualProviderID: .appleContainerization
    )) { error in
      XCTAssertEqual(error as? SchedulerControlOperationError, .authorityUnavailable)
    }
  }

  private func planResponse(
    input: SchedulerEngineInput,
    repository: SchedulerAdmissionRepository,
    authority: @escaping SchedulerControlOperations.AuthorityProvider,
    pressureRefresher: @escaping SchedulerControlOperations.PressureRefresher
  ) throws -> ControlResponseEnvelope {
    let inputValue = try JSONDecoder().decode(
      ControlPlaneJSONValue.self, from: try ControlPlaneCanonicalJSON.encode(input)
    )
    return try XCTUnwrap(SchedulerControlOperations.handle(
      request: ControlRequestEnvelope(
        protocolRevision: .current, requestID: UUID().uuidString,
        operation: "scheduler.plan", timeoutMilliseconds: 1_000,
        body: .object(["projectID": .string(projectUUID), "input": inputValue])
      ), repository: repository, now: { "2026-10-02T23:45:00Z" },
      authorityProvider: authority, pressureRefresher: pressureRefresher
    ))
  }

  private func rawInput(provider: RuntimeProviderID) throws -> SchedulerEngineInput {
    let request = try ResourceVector(["cpu": 1, "memory": 512 * 1_024 * 1_024])
    return try SchedulerEngineInput(
      pendingWorkloads: [SchedulerWorkload(
        requirements: WorkloadPlacementRequirements(workloadID: UUID(), request: request, limit: request),
        priority: 0, subjectID: "owner", projectID: projectUUID
      )], nodes: [SchedulerNode(snapshot: NodePlacementSnapshot(
        nodeID: UUID(), capacity: request, allocation: .zero, architecture: "arm64",
        runtime: "linux-vm", provider: provider.rawValue
      ))]
    )
  }

  private func ownership(provider: RuntimeProviderID) throws -> SchedulerRuntimeOwnershipBinding {
    try SchedulerRuntimeOwnershipBinding(
      resourceIdentifier: RuntimeServiceIdentity(projectName: "demo", serviceName: "api").managedResourceIdentifier,
      resourceType: "container", resourceUUID: UUID().uuidString, resourceGeneration: 1,
      projectUUID: projectUUID, projectName: "demo", projectGeneration: 1,
      serviceName: "api", instanceName: nil, identityVersion: RuntimeManagedResourceIdentity.currentVersion,
      providerID: provider, providerAPIVersion: HostwrightContractVersions.runtimeProviderAPI,
      providerVersion: "0.0.2-dev", providerGeneration: 1, fencingToken: UUID().uuidString
    )
  }
}
