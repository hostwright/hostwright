import Foundation
@testable import HostwrightCLI
import HostwrightControlPlane
import HostwrightPolicy
import HostwrightRuntime
import HostwrightState
import Testing

@Suite
struct LifecycleProfileIntegrationTests {
  @Test
  func exactProfileBindingSurvivesLifecycleParsing() throws {
    let digest = String(repeating: "b", count: 64)
    let command = try CLICommand.parse(arguments: [
      "up", "/tmp/hostwright.yaml", "--state-db", "/tmp/state.sqlite", "--dry-run",
      "--workload-profile-id", "restricted", "--workload-profile-hash", digest,
      "--output", "json",
    ])
    guard case .lifecycle(let options) = command else {
      Issue.record("Expected a lifecycle command.")
      return
    }
    #expect(options.workloadProfileID == "restricted")
    #expect(options.workloadProfileSHA256 == digest)
    #expect(options.dryRun)
  }

  @Test(arguments: [
    ["up", "--dry-run", "--workload-profile-id", "restricted"],
    ["up", "--dry-run", "--workload-profile-hash", String(repeating: "a", count: 64)],
    ["up", "--dry-run", "--workload-profile-id", "../unsafe", "--workload-profile-hash", String(repeating: "a", count: 64)],
    ["up", "--dry-run", "--workload-profile-id", "restricted", "--workload-profile-hash", "invalid"],
  ])
  func incompleteOrUnsafeProfileBindingFailsClosed(arguments: [String]) {
    #expect(throws: CLIUsageError.self) { try CLICommand.parse(arguments: arguments) }
  }

  @Test
  func profileBindingIsPersistedInDesiredRuntimeLabelsAndCannotBeOmitted() throws {
    try withProfileFixture { store, record in
      let service = desiredService()
      let resolved = try WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
        .resolve(id: record.profile.identifier)
      let options = LifecycleCLIOptions(
        command: .up, dryRun: true, workloadProfileID: record.profile.identifier,
        workloadProfileSHA256: resolved.profileSHA256)
      let bound = try lifecycleProfiledServices(
        [service], previous: [], options: options, store: store)
      #expect(bound[0].labels[lifecycleWorkloadProfileIDLabel] == record.profile.identifier)
      #expect(bound[0].labels[lifecycleWorkloadProfileHashLabel] == resolved.profileSHA256)

      #expect(throws: (any Error).self) {
        try lifecycleProfiledServices(
          [service], previous: bound,
          options: LifecycleCLIOptions(command: .update, dryRun: true), store: store)
      }
    }
  }

  @Test
  func switchingToAWeakerProfileFailsBeforeRuntimeMutation() throws {
    try withProfileFixture { store, strict in
      let weakerProfile = profile("weaker", hostAccess: true)
      let weaker = try store.workloadProfiles.create(
        WorkloadProfileRecord(
          profile: weakerProfile, createdBySubjectID: "owner",
          createdAt: "2026-08-03T00:00:00Z", updatedAt: "2026-08-03T00:00:00Z"))
      let service = desiredService()
      let engine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
      let strictResolved = try engine.resolve(id: strict.profile.identifier)
      let weakerResolved = try engine.resolve(id: weaker.profile.identifier)
      let strictBound = try lifecycleProfiledServices(
        [service], previous: [],
        options: LifecycleCLIOptions(
          command: .up, dryRun: true, workloadProfileID: strict.profile.identifier,
          workloadProfileSHA256: strictResolved.profileSHA256), store: store)
      #expect(throws: (any Error).self) {
        try lifecycleProfiledServices(
          [service], previous: strictBound,
          options: LifecycleCLIOptions(
            command: .update, dryRun: true, workloadProfileID: weaker.profile.identifier,
            workloadProfileSHA256: weakerResolved.profileSHA256), store: store)
      }
    }
  }

  @Test
  func mixedPriorProfileAuthorityFailsBeforeRuntimeMutation() throws {
    try withProfileFixture { store, strict in
      let engine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
      let resolution = try engine.resolve(id: strict.profile.identifier)
      let first = desiredService(name: "web")
      let second = desiredService(name: "worker")
      let options = LifecycleCLIOptions(
        command: .up, dryRun: true, workloadProfileID: strict.profile.identifier,
        workloadProfileSHA256: resolution.profileSHA256)
      let boundFirst = try lifecycleProfiledServices(
        [first], previous: [], options: options, store: store)

      #expect(throws: (any Error).self) {
        try lifecycleProfiledServices(
          [first, second], previous: [boundFirst[0], second],
          options: options, store: store)
      }
    }
  }

  private func withProfileFixture(
    _ body: (SQLiteStateStore, WorkloadProfileRecord) throws -> Void
  ) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hostwright-lifecycle-profile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteStateStore(path: root.appendingPathComponent("state.sqlite").path)
    try store.migrate()
    let timestamp = "2026-08-03T00:00:00Z"
    try store.controlIdentities.bootstrap(
      ControlPeerIdentityRecord(
        subjectID: "owner", userID: 501,
        codeIdentity: CodeIdentity(
          teamIdentifier: "993YC3JY4Q", signingIdentifier: "hostwright-test",
          codeDirectoryHash: String(repeating: "a", count: 40),
          validationMode: .installedRequirement),
        declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp))
    let record = try store.workloadProfiles.create(
      WorkloadProfileRecord(
        profile: profile("strict", hostAccess: false), createdBySubjectID: "owner",
        createdAt: timestamp, updatedAt: timestamp))
    try body(store, record)
  }

  private func profile(_ identifier: String, hostAccess: Bool) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier,
      filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
      network: NetworkProfile(mode: .isolated),
      secrets: SecretsProfile(), images: ImagesProfile(requireDigest: false, requireSignature: false),
      runtime: RuntimeProfile(), hostAccess: HostAccessProfile(allowed: hostAccess),
      observability: ObservabilityProfile(logs: true, metrics: true, traces: true),
      accelerators: AcceleratorsProfile(), syscalls: SyscallProfile(defaultDeny: false))
  }

  private func desiredService(name: String = "web") -> DesiredRuntimeService {
    DesiredRuntimeService(
      identity: RuntimeServiceIdentity(projectName: "profile", serviceName: name),
      image: "busybox", readOnlyRootFilesystem: true)
  }
}
