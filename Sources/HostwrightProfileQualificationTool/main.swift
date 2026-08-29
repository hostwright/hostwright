import Foundation
import HostwrightControlPlane
import HostwrightCore
import HostwrightPolicy
import HostwrightRuntime
import HostwrightState

private struct ProfileQualificationResult: Encodable {
  let kind = "hostwright.phase09.profile.qualification.v1"
  let stateSchemaVersion: Int
  let integrityHealth: String
  let providerID: String
  let providerCapabilitySHA256: String
  let appleContainerCapabilityProbed: Bool
  let supportedProfileAllowed: Bool
  let liveWorkloadValidated: Bool
  let unsupportedProfileDenied: Bool
  let admissionBound: Bool
  let inheritanceResolved: Bool
  let driftDetected: Bool
  let persistedAcrossReopen: Bool
}

@main
enum HostwrightProfileQualificationTool {
  static func main() async throws {
    let root = try qualificationRoot()
    let path = root.appendingPathComponent("state.sqlite").path
    let store = SQLiteStateStore(path: path)
    try store.migrate()
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    try store.controlIdentities.bootstrap(identity(at: timestamp))
    try store.rbac.bootstrapDefaultRolesAndOwner(subjectID: "owner", timestamp: timestamp)
    let authorizer = RBACAuthorizationEngine(repository: store.rbac)
    let administration = WorkloadProfileAdministrationService(
      repository: store.workloadProfiles, authorizer: authorizer)
    let base = supportedProfile(identifier: "qualification.base")
    let storedBase = try administration.create(
      base, approval: nil, actorSubjectID: "owner", at: now)
    let child = supportedProfile(identifier: "qualification.child", parent: base.identifier, memoryMiB: 256)
    _ = try administration.create(child, approval: nil, actorSubjectID: "owner", at: now)
    let unsupported = unsupportedProfile(identifier: "qualification.unsupported")
    _ = try administration.create(unsupported, approval: nil, actorSubjectID: "owner", at: now)

    let engine = WorkloadProfilePolicyEngine(repository: store.workloadProfiles)
    let resolution = try engine.resolve(id: child.identifier)
    let unsupportedResolution = try engine.resolve(id: unsupported.identifier)
    let snapshot = try await RuntimeProviderCapabilityProbe().probeAppleContainerCLI()
    var supportedAccepted = false
    do {
      try engine.validateProvider(resolution, snapshot: snapshot)
      supportedAccepted = true
    } catch {}
    let imageLock = try RuntimeImageDigestLock(
      requestedReference: "docker.io/library/python:alpine",
      resolvedReference:
        "docker.io/library/python@sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92",
      descriptorDigest:
        "sha256:26730869004e2b9c4b9ad09cab8625e81d256d1ce97e72df5520e806b1709f92",
      variantDigest:
        "sha256:ea1c84f6f8fd70586985617ca87516c75e583748885d70515d83c7f3c8e94174",
      operatingSystem: "linux", architecture: "arm64", providerID: .appleContainerCLI,
      capabilitySHA256: snapshot.canonicalSHA256)
    let workload = DesiredRuntimeService(
      identity: RuntimeServiceIdentity(
        projectName: "phase09-gate07", serviceName: "profile-live"),
      image: imageLock.resolvedReference, imageLock: imageLock,
      cpuCount: 1, memoryBytes: 64 * 1_024 * 1_024,
      readOnlyRootFilesystem: true)
    var workloadValidated = false
    do {
      try engine.validateWorkload(workload, resolution: resolution, snapshot: snapshot)
      workloadValidated = true
    } catch {}
    var unsupportedDenied = false
    do {
      try engine.validateProvider(unsupportedResolution, snapshot: snapshot)
    } catch WorkloadProfilePolicyError.unsupportedCapabilities {
      unsupportedDenied = true
    }

    let admission = AdmissionPolicyEngine(
      repository: store.admission, workloadProfileResolver: { try engine.resolve(id: $0) })
    let request = ControlRequestEnvelope(
      requestID: "profile-live", operation: "service.update", timeoutMilliseconds: 1_000,
      idempotencyKey: "profile-live-key",
      body: .object(["workloadProfileID": .string(child.identifier), "dryRun": .bool(true)]))
    let evaluated = try admission.evaluate(subjectID: "owner", request: request, at: now)
    let admissionHash: String?
    if case .object(let fields)? = evaluated.effectiveRequest.body,
      case .string(let value)? = fields["profileHash"] { admissionHash = value }
    else { admissionHash = nil }
    let drift = try engine.drift(id: child.identifier, observedProfileSHA256: storedBase.profileSHA256)
    let integrity = StateIntegrityService(store: store).inspect()
    let reopened = SQLiteStateStore(path: path)
    let persisted = try reopened.workloadProfiles.listProfiles().count == 3
      && WorkloadProfilePolicyEngine(repository: reopened.workloadProfiles)
        .resolve(id: child.identifier).profileSHA256 == resolution.profileSHA256

    let result = ProfileQualificationResult(
      stateSchemaVersion: try store.schemaVersion(), integrityHealth: integrity.health.rawValue,
      providerID: snapshot.descriptor.providerID.rawValue,
      providerCapabilitySHA256: snapshot.canonicalSHA256,
      appleContainerCapabilityProbed: true,
      supportedProfileAllowed: supportedAccepted,
      liveWorkloadValidated: workloadValidated,
      unsupportedProfileDenied: unsupportedDenied,
      admissionBound: admissionHash == resolution.profileSHA256,
      inheritanceResolved: resolution.inheritance == [base.identifier, child.identifier],
      driftDetected: drift.drifted, persistedAcrossReopen: persisted)
    guard result.stateSchemaVersion == HostwrightContractVersions.stateSchema,
      integrity.health == .healthy,
      result.providerID == RuntimeProviderID.appleContainerCLI.rawValue,
      result.providerCapabilitySHA256.count == 64, result.appleContainerCapabilityProbed,
      result.supportedProfileAllowed, result.liveWorkloadValidated,
      result.unsupportedProfileDenied, result.admissionBound,
      result.inheritanceResolved, result.driftDetected, result.persistedAcrossReopen
    else {
      throw StateStoreError.transactionInvariantViolation(
        message: "Workload-profile live qualification failed.")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
  }

  private static func qualificationRoot() throws -> URL {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, arguments[1] == "--root",
      arguments[3] == "--probe-apple-container" else {
      throw StateStoreError.invalidRecord(
        "Usage: hostwright-profile-qualification --root PATH --probe-apple-container")
    }
    let root = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
    guard root.path == arguments[2], values.isDirectory == true, values.isSymbolicLink != true,
      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
      (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
    else { throw StateStoreError.invalidRecord("Qualification root is unsafe.") }
    return root
  }

  private static func identity(at timestamp: String) -> ControlPeerIdentityRecord {
    ControlPeerIdentityRecord(
      subjectID: "owner", userID: UInt32(geteuid()),
      codeIdentity: CodeIdentity(
        teamIdentifier: "993YC3JY4Q", signingIdentifier: "dev.hostwright.profile-qualification",
        codeDirectoryHash: String(repeating: "a", count: 40),
        validationMode: .installedRequirement),
      declaredBySubjectID: "owner", declaredAt: timestamp, updatedAt: timestamp)
  }

  private static func supportedProfile(
    identifier: String, parent: String? = nil, memoryMiB: Int = 256
  ) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier, parent: parent,
      filesystem: FilesystemProfile(readOnlyRoot: true, denyHostRoot: true),
      network: NetworkProfile(mode: .isolated),
      resources: ResourceProfile(cpu: 2, memoryMiB: memoryMiB),
      identity: nil, secrets: SecretsProfile(),
      images: ImagesProfile(requireDigest: true, requireSignature: false),
      runtime: RuntimeProfile(allowedProviders: [RuntimeProviderID.appleContainerCLI.rawValue]),
      hostAccess: HostAccessProfile(allowed: false),
      observability: ObservabilityProfile(logs: true, metrics: true, traces: true),
      accelerators: AcceleratorsProfile(),
      syscalls: SyscallProfile(defaultDeny: false))
  }

  private static func unsupportedProfile(identifier: String) -> WorkloadProfile {
    WorkloadProfile(
      identifier: identifier,
      filesystem: FilesystemProfile(
        readOnlyRoot: true, allowReadPaths: ["/app"], denyHostRoot: true),
      network: NetworkProfile(mode: .isolated), resources: ResourceProfile(memoryMiB: 256),
      identity: IdentityProfile(allowRoot: false), secrets: SecretsProfile(),
      images: ImagesProfile(requireDigest: true, requireSignature: true),
      runtime: RuntimeProfile(allowedProviders: [RuntimeProviderID.appleContainerCLI.rawValue]),
      hostAccess: HostAccessProfile(allowed: false),
      observability: ObservabilityProfile(logs: true, metrics: true, traces: true),
      accelerators: AcceleratorsProfile(), syscalls: SyscallProfile(defaultDeny: true))
  }
}
