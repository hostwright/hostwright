import Foundation
import XCTest

@testable import HostwrightControlPlane
@testable import HostwrightPolicy
@testable import HostwrightRuntime
@testable import HostwrightState

final class WorkloadProfilePolicyEngineTests: XCTestCase {
  private let at = ISO8601DateFormatter().date(from: "2026-08-03T00:00:00Z")!

  func testProfileV1RejectsInvalidVersionPathsNetworkIdentityAndGrants() throws {
    var invalid = profile("invalid")
    invalid = WorkloadProfile(
      version: 2, identifier: invalid.identifier, filesystem: invalid.filesystem,
      network: invalid.network, resources: invalid.resources, identity: invalid.identity,
      secrets: invalid.secrets, images: invalid.images, runtime: invalid.runtime,
      hostAccess: invalid.hostAccess, observability: invalid.observability,
      accelerators: invalid.accelerators, syscalls: invalid.syscalls,
      extensionGrants: invalid.extensionGrants)
    XCTAssertThrowsError(try invalid.validate())

    let unsafe = profile("unsafe", filesystem: FilesystemProfile(
      readOnlyRoot: true, allowReadPaths: ["/tmp", "/tmp"], allowWritePaths: ["/tmp"],
      denyHostRoot: true))
    XCTAssertThrowsError(try unsafe.validate())
    let isolatedOrigins = profile("isolated-origins", network: NetworkProfile(
      mode: .isolated, allowedOrigins: ["https://example.test"]))
    XCTAssertThrowsError(try isolatedOrigins.validate())
    let root = profile("root", identity: IdentityProfile(runAsUser: 0, runAsGroup: 0))
    XCTAssertThrowsError(try root.validate())
    let duplicateGrants = profile("duplicate-grants", extensionGrants: [
      PluginGrant(capability: .policy, scope: "project-a"),
      PluginGrant(capability: .policy, scope: "project-a"),
    ])
    XCTAssertThrowsError(try duplicateGrants.validate())
    XCTAssertThrowsError(try profile("../unsafe").validate())
    XCTAssertThrowsError(try profile(
      "insecure-origin",
      network: NetworkProfile(mode: .brokered, allowedOrigins: ["http://example.test"])
    ).validate())
  }

  func testResolutionInheritsOptionalLimitsAndProducesStableHash() throws {
    try withFixture { fixture in
      let parent = profile("parent", resources: ResourceProfile(cpu: 2, memoryMiB: 256),
                           identity: IdentityProfile(runAsUser: 501, runAsGroup: 20))
      _ = try fixture.create(parent)
      let child = profile("child", parent: "parent", resources: nil, identity: nil)
      let storedChild = try fixture.create(child)
      XCTAssertEqual(storedChild.profile.identifier, "child")

      let first = try fixture.engine.resolve(id: "child")
      let second = try fixture.engine.resolve(id: "child")
      XCTAssertEqual(first.inheritance, ["parent", "child"])
      XCTAssertEqual(first.profile.resources, parent.resources)
      XCTAssertEqual(first.profile.identity, parent.identity)
      XCTAssertEqual(first.profileSHA256, second.profileSHA256)
      XCTAssertEqual(first.sourceDigests.count, 2)
      XCTAssertNotEqual(first.profileSHA256, try WorkloadProfileRecord.digest(child))
    }
  }

  func testWeakeningReasonsCoverEveryFrozenProfileDimension() throws {
    let base = profile(
      "base",
      filesystem: FilesystemProfile(
        readOnlyRoot: true, allowReadPaths: ["/tmp", "/var"], allowWritePaths: ["/tmp"],
        denyHostRoot: true),
      network: NetworkProfile(mode: .isolated),
      resources: ResourceProfile(cpu: 1, memoryMiB: 64, processCount: 1),
      identity: IdentityProfile(runAsUser: 501, runAsGroup: 20),
      secrets: SecretsProfile(allowedReferences: ["secret-a"]),
      images: ImagesProfile(requireDigest: true, requireSignature: true),
      runtime: RuntimeProfile(allowedProviders: ["provider-a"], deniedOptions: ["virtualization"]),
      hostAccess: HostAccessProfile(allowed: false),
      observability: ObservabilityProfile(logs: false, metrics: false, traces: false),
      accelerators: AcceleratorsProfile(allowed: ["gpu"]),
      syscalls: SyscallProfile(defaultDeny: true, allowed: ["read"], denied: ["mount"]),
      extensionGrants: [PluginGrant(capability: .policy, scope: "project-a")])
    let weaker = profile(
      "weaker",
      filesystem: FilesystemProfile(
        readOnlyRoot: false, allowReadPaths: ["/opt", "/tmp", "/var"],
        allowWritePaths: ["/opt", "/tmp"], denyHostRoot: false),
      network: NetworkProfile(mode: .brokered, allowedOrigins: ["https://example.test"]),
      resources: ResourceProfile(cpu: 2, memoryMiB: 128, processCount: 2),
      identity: IdentityProfile(runAsUser: 0, runAsGroup: 0, allowRoot: true),
      secrets: SecretsProfile(allowedReferences: ["secret-a", "secret-b"]),
      images: ImagesProfile(requireDigest: false, requireSignature: false),
      runtime: RuntimeProfile(allowedProviders: ["provider-a", "provider-b"]),
      hostAccess: HostAccessProfile(allowed: true),
      observability: ObservabilityProfile(logs: true, metrics: true, traces: true),
      accelerators: AcceleratorsProfile(allowed: ["gpu", "neural"]),
      syscalls: SyscallProfile(defaultDeny: false, allowed: ["read", "write"]),
      extensionGrants: [
        PluginGrant(capability: .network, scope: "project-a"),
        PluginGrant(capability: .policy, scope: "project-a"),
      ])
    XCTAssertEqual(WorkloadProfilePolicyEngine.weakeningReasons(candidate: weaker, base: base), [
      "accelerators.allowed", "extensionGrants", "filesystem.allowReadPaths",
      "filesystem.allowWritePaths", "filesystem.denyHostRoot", "filesystem.readOnlyRoot",
      "hostAccess.allowed", "identity.allowRoot", "identity.runAsGroup", "identity.runAsUser",
      "images.requireDigest", "images.requireSignature", "network.allowedOrigins", "network.mode",
      "observability.logs", "observability.metrics", "observability.traces", "resources.cpu",
      "resources.memoryMiB", "resources.processCount", "runtime.allowedProviders",
      "runtime.deniedOptions", "secrets.allowedReferences", "syscalls.allowed", "syscalls.defaultDeny",
      "syscalls.denied",
    ])
  }

  func testRuntimeAllowedProviderInheritanceTreatsEmptyBaseAsUnrestricted() {
    let unrestricted = profile("unrestricted", runtime: RuntimeProfile())
    let restricted = profile(
      "restricted", runtime: RuntimeProfile(allowedProviders: ["apple-container-cli"]))
    let narrower = profile(
      "narrower", runtime: RuntimeProfile(allowedProviders: ["apple-container-cli"]))
    let broaderBase = profile(
      "broader-base", runtime: RuntimeProfile(
        allowedProviders: ["apple-container-cli", "apple-containerization"]))
    let defaultBase = profile(
      "default-base", runtime: RuntimeProfile(allowedProviders: ["default"]))
    let defaultCandidate = profile(
      "default-candidate", runtime: RuntimeProfile(allowedProviders: ["default"]))

    XCTAssertEqual(
      WorkloadProfilePolicyEngine.weakeningReasons(candidate: restricted, base: unrestricted), [])
    XCTAssertEqual(
      WorkloadProfilePolicyEngine.weakeningReasons(candidate: unrestricted, base: restricted),
      ["runtime.allowedProviders"])
    XCTAssertEqual(
      WorkloadProfilePolicyEngine.weakeningReasons(candidate: narrower, base: broaderBase), [])
    XCTAssertEqual(
      WorkloadProfilePolicyEngine.weakeningReasons(candidate: restricted, base: defaultBase), [])
    XCTAssertEqual(
      WorkloadProfilePolicyEngine.weakeningReasons(candidate: defaultCandidate, base: restricted),
      ["runtime.allowedProviders"])
  }

  func testWeakeningRequiresExactRbacApprovedFutureApproval() throws {
    try withFixture { fixture in
      let parent = profile("parent")
      _ = try fixture.create(parent)
      let child = profile("child", parent: "parent", hostAccess: HostAccessProfile(allowed: true))
      XCTAssertThrowsError(try fixture.administration.create(
        child, approval: nil, actorSubjectID: "owner", at: at)) { error in
        XCTAssertEqual(error as? WorkloadProfilePolicyError, .weakeningRequiresApproval(["hostAccess.allowed"]))
      }
      let parentResolution = try fixture.engine.resolve(id: "parent")
      let candidate = try fixture.engine.proposedResolution(child).profileSHA256
      let expired = WorkloadProfileWeakeningApproval(
        profileIdentifier: "child", baseProfileSHA256: parentResolution.profileSHA256,
        candidateProfileSHA256: candidate, approvalIdentity: "owner", expiresAt: "2026-08-02T23:59:59Z")
      XCTAssertThrowsError(try fixture.administration.create(
        child, approval: expired, actorSubjectID: "owner", at: at))
      let approval = WorkloadProfileWeakeningApproval(
        profileIdentifier: "child", baseProfileSHA256: parentResolution.profileSHA256,
        candidateProfileSHA256: candidate, approvalIdentity: "owner", expiresAt: "2026-08-03T01:00:00Z")
      XCTAssertEqual(
        try fixture.administration.create(child, approval: approval, actorSubjectID: "owner", at: at)
          .profile.identifier,
        "child")
    }
  }

  func testWeakeningApprovalCannotReplayAfterInheritedBaseChanges() throws {
    try withFixture { fixture in
      let parent = profile("parent", resources: ResourceProfile(cpu: 2, memoryMiB: 256))
      let storedParent = try fixture.create(parent)
      _ = try fixture.create(profile("child", parent: "parent", resources: nil))
      let candidate = profile(
        "child", parent: "parent", resources: nil,
        hostAccess: HostAccessProfile(allowed: true))
      let oldBase = try fixture.engine.resolve(id: "child")
      let oldCandidate = try fixture.engine.proposedResolution(candidate)
      let approval = WorkloadProfileWeakeningApproval(
        profileIdentifier: "child", baseProfileSHA256: oldBase.profileSHA256,
        candidateProfileSHA256: oldCandidate.profileSHA256, approvalIdentity: "owner",
        expiresAt: "2026-08-03T01:00:00Z")

      _ = try fixture.administration.update(
        profile("parent", resources: ResourceProfile(cpu: 1, memoryMiB: 128)),
        expectedGeneration: storedParent.generation, approval: nil,
        actorSubjectID: "owner", at: at)

      XCTAssertThrowsError(try fixture.administration.update(
        candidate, expectedGeneration: 1, approval: approval,
        actorSubjectID: "owner", at: at)) { error in
        guard case .weakeningRequiresApproval = error as? WorkloadProfilePolicyError else {
          return XCTFail("Expected inherited approval replay denial, got \(error)")
        }
      }
    }
  }

  func testProviderCapabilityDesiredWorkloadAndDriftFailuresAreExplicit() throws {
    try withFixture { fixture in
      let constrainedProfile = profile(
        "enforced",
        filesystem: FilesystemProfile(
          readOnlyRoot: true, allowReadPaths: ["/tmp"], denyHostRoot: true),
        network: NetworkProfile(mode: .brokered, allowedOrigins: ["https://example.test"]),
        resources: ResourceProfile(cpu: 1, memoryMiB: 64, processCount: 1),
        identity: IdentityProfile(runAsUser: 501, runAsGroup: 20),
        images: ImagesProfile(requireDigest: true, requireSignature: true),
        runtime: RuntimeProfile(allowedProviders: ["apple-container-cli"]),
        hostAccess: HostAccessProfile(allowed: false),
        accelerators: AcceleratorsProfile(allowed: ["gpu"]),
        syscalls: SyscallProfile(defaultDeny: true, allowed: ["read"], denied: ["mount"]),
        extensionGrants: [PluginGrant(capability: .policy, scope: "project-a")])
      _ = try fixture.create(constrainedProfile)
      let resolution = try fixture.engine.resolve(id: "enforced")
      let noCapabilities = snapshot(provider: .appleContainerCLI, features: [])
      XCTAssertThrowsError(try fixture.engine.validateProvider(resolution, snapshot: noCapabilities)) { error in
        XCTAssertEqual(error as? WorkloadProfilePolicyError, .unsupportedCapabilities([
          "accelerators", "extensionGrants", "filesystem.path-allowlist", "images.runtime-signature-enforcement",
          "network.allowedOrigins", "network.brokered", "resources.processCount", "syscalls",
        ]))
      }
      XCTAssertThrowsError(try fixture.engine.validateProvider(
        resolution, snapshot: snapshot(provider: RuntimeProviderID(rawValue: "other"), features: []))) { error in
        XCTAssertEqual(error as? WorkloadProfilePolicyError, .providerMismatch("other"))
      }
      let supported = snapshot(provider: .appleContainerCLI, features: [.networks])
      let service = DesiredRuntimeService(
        identity: RuntimeServiceIdentity(projectName: "profile", serviceName: "service"), image: "busybox",
        cpuCount: 2, memoryBytes: 128 * 1_024 * 1_024, userID: 0, groupID: 0,
        readOnlyRootFilesystem: false)
      XCTAssertThrowsError(try fixture.engine.validateWorkload(
        service, resolution: resolution, snapshot: supported)) { error in
        XCTAssertEqual(error as? WorkloadProfilePolicyError, .unsupportedCapabilities([
          "accelerators", "extensionGrants", "filesystem.path-allowlist", "images.runtime-signature-enforcement",
          "network.allowedOrigins", "resources.processCount", "syscalls",
        ]))
      }
      let drift = try fixture.engine.drift(
        id: "enforced", observedProfileSHA256: String(repeating: "f", count: 64),
        observedReasons: ["runtime-disappeared", "runtime-disappeared"])
      XCTAssertTrue(drift.drifted)
      XCTAssertEqual(drift.reasons, ["runtime-disappeared"])

      let enforcing = profile(
        "workload", resources: ResourceProfile(cpu: 1, memoryMiB: 64),
        identity: IdentityProfile(runAsUser: 501, runAsGroup: 20),
        images: ImagesProfile(requireDigest: true, requireSignature: false))
      _ = try fixture.create(enforcing)
      let enforced = try fixture.engine.resolve(id: "workload")
      XCTAssertThrowsError(try fixture.engine.validateWorkload(
        service, resolution: enforced, snapshot: noCapabilities)) { error in
        XCTAssertEqual(error as? WorkloadProfilePolicyError, .workloadViolation([
          "filesystem.readOnlyRoot", "identity.allowRoot", "identity.runAsGroup",
          "identity.runAsUser", "images.requireDigest", "resources.cpu", "resources.memoryMiB",
        ]))
      }
    }
  }

  func testLegacyRequestsWithoutProfileRemainUnbound() throws {
    try withFixture { fixture in
      let engine = AdmissionPolicyEngine(repository: fixture.store.admission)
      let evaluation = try engine.evaluate(
        subjectID: "owner", request: ControlRequestEnvelope(
          requestID: "legacy", operation: "service.update", timeoutMilliseconds: 1_000,
          body: .object(["projectUUID": .string("project-a")])), at: at)
      XCTAssertTrue(evaluation.allowed)
      XCTAssertNil((evaluation.effectiveRequest.body.flatMap { value -> ControlPlaneJSONValue? in
        guard case .object(let fields) = value else { return nil }; return fields["profileHash"]
      }))
    }
  }

  private func profile(
    _ identifier: String, parent: String? = nil,
    filesystem: FilesystemProfile = FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
    network: NetworkProfile = NetworkProfile(mode: .isolated), resources: ResourceProfile? = nil,
    identity: IdentityProfile? = nil, secrets: SecretsProfile = SecretsProfile(),
    images: ImagesProfile = ImagesProfile(requireDigest: false, requireSignature: false),
    runtime: RuntimeProfile = RuntimeProfile(), hostAccess: HostAccessProfile = HostAccessProfile(allowed: false),
    observability: ObservabilityProfile = ObservabilityProfile(logs: false, metrics: false, traces: false),
    accelerators: AcceleratorsProfile = AcceleratorsProfile(),
    syscalls: SyscallProfile = SyscallProfile(defaultDeny: false), extensionGrants: [PluginGrant] = []
  ) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier, parent: parent, filesystem: filesystem, network: network,
      resources: resources, identity: identity, secrets: secrets, images: images, runtime: runtime,
      hostAccess: hostAccess, observability: observability, accelerators: accelerators,
      syscalls: syscalls, extensionGrants: extensionGrants)
  }

  private func snapshot(
    provider: RuntimeProviderID, features: [RuntimeProviderFeature]
  ) -> RuntimeCapabilitySnapshot {
    RuntimeCapabilitySnapshot(
      descriptor: RuntimeProviderDescriptor(providerID: provider, components: [],
        minimumMacOSVersion: RuntimeProviderMacOSVersion(major: 26), supportedArchitectures: [.arm64]),
      host: RuntimeProviderHostPlatform(
        macOSVersion: RuntimeProviderMacOSVersion(major: 26), macOSBuild: "test", architecture: .arm64),
      features: features.map {
        RuntimeProviderFeatureStatus(feature: $0, state: .available, reason: .implemented)
      })
  }

  private func withFixture(_ body: (Fixture) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-profile-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let timestamp = "2026-08-02T20:00:00Z"
    try store.controlIdentities.bootstrap(ControlPeerIdentityRecord(
      subjectID: "owner", userID: 501,
      codeIdentity: CodeIdentity(teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test",
        codeDirectoryHash: String(repeating: "a", count: 40), validationMode: .installedRequirement),
      declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    let authorizer = RBACAuthorizationEngine(repository: store.rbac)
    try body(Fixture(store: store, engine: WorkloadProfilePolicyEngine(repository: store.workloadProfiles),
      administration: WorkloadProfileAdministrationService(repository: store.workloadProfiles, authorizer: authorizer)))
  }

  private struct Fixture {
    let store: SQLiteStateStore
    let engine: WorkloadProfilePolicyEngine
    let administration: WorkloadProfileAdministrationService
    func create(_ profile: WorkloadProfile) throws -> WorkloadProfileRecord {
      try administration.create(profile, approval: nil, actorSubjectID: "owner",
        at: ISO8601DateFormatter().date(from: "2026-08-03T00:00:00Z")!)
    }
  }
}
