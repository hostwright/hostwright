import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightRuntime
import HostwrightState

public enum WorkloadProfilePolicyError: Error, Equatable, Sendable {
  case missingProfile(String)
  case inheritanceTooDeep
  case inheritanceCycle
  case weakeningRequiresApproval([String])
  case invalidWeakeningApproval
  case providerMismatch(String)
  case unsupportedCapabilities([String])
  case workloadViolation([String])
}

public struct WorkloadProfileResolution: Codable, Equatable, Sendable {
  public let profile: WorkloadProfile
  public let profileSHA256: String
  public let inheritance: [String]
  public let sourceDigests: [String]

  public init(
    profile: WorkloadProfile, profileSHA256: String,
    inheritance: [String], sourceDigests: [String]
  ) {
    self.profile = profile
    self.profileSHA256 = profileSHA256
    self.inheritance = inheritance
    self.sourceDigests = sourceDigests
  }
}

public struct WorkloadProfileWeakeningApproval: Codable, Equatable, Sendable {
  public let profileIdentifier: String
  public let baseProfileSHA256: String
  public let candidateProfileSHA256: String
  public let approvalIdentity: String
  public let expiresAt: String

  public init(
    profileIdentifier: String, baseProfileSHA256: String, candidateProfileSHA256: String,
    approvalIdentity: String, expiresAt: String
  ) {
    self.profileIdentifier = profileIdentifier
    self.baseProfileSHA256 = baseProfileSHA256
    self.candidateProfileSHA256 = candidateProfileSHA256
    self.approvalIdentity = approvalIdentity
    self.expiresAt = expiresAt
  }
}

public struct WorkloadProfileDrift: Codable, Equatable, Sendable {
  public let profileIdentifier: String
  public let expectedProfileSHA256: String
  public let observedProfileSHA256: String?
  public let reasons: [String]
  public var drifted: Bool { observedProfileSHA256 != expectedProfileSHA256 || !reasons.isEmpty }
}

public struct WorkloadProfilePolicyEngine: Sendable {
  public static let maximumInheritanceDepth = 32
  private let repository: WorkloadProfileRepository

  public init(repository: WorkloadProfileRepository) { self.repository = repository }

  public func resolve(id: String) throws -> WorkloadProfileResolution {
    var records: [WorkloadProfileRecord] = []
    var seen = Set<String>()
    var next: String? = id
    while let current = next {
      guard records.count < Self.maximumInheritanceDepth else {
        throw WorkloadProfilePolicyError.inheritanceTooDeep
      }
      guard seen.insert(current).inserted else {
        throw WorkloadProfilePolicyError.inheritanceCycle
      }
      guard let record = try repository.profile(id: current) else {
        throw WorkloadProfilePolicyError.missingProfile(current)
      }
      records.append(record)
      next = record.profile.parent
    }
    guard var effective = records.last?.profile else {
      throw WorkloadProfilePolicyError.missingProfile(id)
    }
    for record in records.dropLast().reversed() {
      effective = Self.materialized(child: record.profile, parent: effective)
    }
    let chain = records.reversed()
    let digest = try Self.resolutionDigest(
      profile: effective, sourceDigests: chain.map(\.profileSHA256))
    return WorkloadProfileResolution(
      profile: effective, profileSHA256: digest,
      inheritance: chain.map(\.profile.identifier), sourceDigests: chain.map(\.profileSHA256))
  }

  public func proposedResolution(_ profile: WorkloadProfile) throws -> WorkloadProfileResolution {
    try profile.validate()
    let recordSHA256 = try WorkloadProfileRecord.digest(profile)
    if let parentID = profile.parent {
      let parent = try resolve(id: parentID)
      let effective = Self.materialized(child: profile, parent: parent.profile)
      let sourceDigests = parent.sourceDigests + [recordSHA256]
      return WorkloadProfileResolution(
        profile: effective,
        profileSHA256: try Self.resolutionDigest(
          profile: effective, sourceDigests: sourceDigests),
        inheritance: parent.inheritance + [profile.identifier],
        sourceDigests: sourceDigests)
    }
    return WorkloadProfileResolution(
      profile: profile,
      profileSHA256: try Self.resolutionDigest(
        profile: profile, sourceDigests: [recordSHA256]),
      inheritance: [profile.identifier], sourceDigests: [recordSHA256])
  }

  public static func weakeningReasons(candidate: WorkloadProfile, base: WorkloadProfile) -> [String] {
    var reasons: [String] = []
    func subset<T: Hashable>(_ candidate: [T], _ base: [T], _ reason: String) {
      if !Set(candidate).isSubset(of: Set(base)) { reasons.append(reason) }
    }
    func superset<T: Hashable>(_ candidate: [T], _ base: [T], _ reason: String) {
      if !Set(candidate).isSuperset(of: Set(base)) { reasons.append(reason) }
    }
    if base.filesystem.readOnlyRoot && !candidate.filesystem.readOnlyRoot {
      reasons.append("filesystem.readOnlyRoot")
    }
    if base.filesystem.denyHostRoot && !candidate.filesystem.denyHostRoot {
      reasons.append("filesystem.denyHostRoot")
    }
    subset(candidate.filesystem.allowReadPaths, base.filesystem.allowReadPaths, "filesystem.allowReadPaths")
    subset(candidate.filesystem.allowWritePaths, base.filesystem.allowWritePaths, "filesystem.allowWritePaths")
    if base.network.mode == .isolated && candidate.network.mode != .isolated {
      reasons.append("network.mode")
    }
    subset(candidate.network.allowedOrigins, base.network.allowedOrigins, "network.allowedOrigins")
    compareLimit(candidate.resources?.cpu, base.resources?.cpu, "resources.cpu", into: &reasons)
    compareLimit(candidate.resources?.memoryMiB, base.resources?.memoryMiB, "resources.memoryMiB", into: &reasons)
    compareLimit(candidate.resources?.processCount, base.resources?.processCount, "resources.processCount", into: &reasons)
    compareIdentity(candidate.identity?.runAsUser, base.identity?.runAsUser, "identity.runAsUser", into: &reasons)
    compareIdentity(candidate.identity?.runAsGroup, base.identity?.runAsGroup, "identity.runAsGroup", into: &reasons)
    if base.identity?.allowRoot == false && candidate.identity?.allowRoot != false {
      reasons.append("identity.allowRoot")
    }
    subset(candidate.secrets.allowedReferences, base.secrets.allowedReferences, "secrets.allowedReferences")
    if base.images.requireDigest && !candidate.images.requireDigest { reasons.append("images.requireDigest") }
    if base.images.requireSignature && !candidate.images.requireSignature { reasons.append("images.requireSignature") }
    let candidateProviders = Set(candidate.runtime.allowedProviders)
    let baseProviders = Set(base.runtime.allowedProviders)
    let baseProvidersUnrestricted = baseProviders.isEmpty || baseProviders.contains("default")
    let candidateProvidersUnrestricted =
      candidateProviders.isEmpty || candidateProviders.contains("default")
    if !baseProvidersUnrestricted
      && (candidateProvidersUnrestricted || !candidateProviders.isSubset(of: baseProviders)) {
      reasons.append("runtime.allowedProviders")
    }
    superset(candidate.runtime.deniedOptions, base.runtime.deniedOptions, "runtime.deniedOptions")
    if !base.hostAccess.allowed && candidate.hostAccess.allowed { reasons.append("hostAccess.allowed") }
    if !base.observability.logs && candidate.observability.logs { reasons.append("observability.logs") }
    if !base.observability.metrics && candidate.observability.metrics { reasons.append("observability.metrics") }
    if !base.observability.traces && candidate.observability.traces { reasons.append("observability.traces") }
    subset(candidate.accelerators.allowed, base.accelerators.allowed, "accelerators.allowed")
    if base.syscalls.defaultDeny && !candidate.syscalls.defaultDeny { reasons.append("syscalls.defaultDeny") }
    subset(candidate.syscalls.allowed, base.syscalls.allowed, "syscalls.allowed")
    superset(candidate.syscalls.denied, base.syscalls.denied, "syscalls.denied")
    let candidateGrants = Set(candidate.extensionGrants.map { "\($0.capability.rawValue)\u{0}\($0.scope)" })
    let baseGrants = Set(base.extensionGrants.map { "\($0.capability.rawValue)\u{0}\($0.scope)" })
    if !candidateGrants.isSubset(of: baseGrants) { reasons.append("extensionGrants") }
    return Array(Set(reasons)).sorted()
  }

  public func validateProvider(
    _ resolution: WorkloadProfileResolution, snapshot: RuntimeCapabilitySnapshot
  ) throws {
    let provider = snapshot.descriptor.providerID.rawValue
    let allowed = resolution.profile.runtime.allowedProviders
    guard allowed.isEmpty || allowed.contains("default") || allowed.contains(provider) else {
      throw WorkloadProfilePolicyError.providerMismatch(provider)
    }
    var gaps: [String] = []
    let available = Set(snapshot.features.filter {
      $0.state == .available && $0.reason == .implemented
    }.map { $0.feature.rawValue })
    if resolution.profile.network.mode == .brokered && !available.contains(RuntimeProviderFeature.networks.rawValue) {
      gaps.append("network.brokered")
    }
    if !resolution.profile.network.allowedOrigins.isEmpty { gaps.append("network.allowedOrigins") }
    if !resolution.profile.filesystem.allowReadPaths.isEmpty
      || !resolution.profile.filesystem.allowWritePaths.isEmpty { gaps.append("filesystem.path-allowlist") }
    if resolution.profile.resources?.processCount != nil { gaps.append("resources.processCount") }
    if !resolution.profile.accelerators.allowed.isEmpty { gaps.append("accelerators") }
    if resolution.profile.syscalls.defaultDeny || !resolution.profile.syscalls.allowed.isEmpty
      || !resolution.profile.syscalls.denied.isEmpty { gaps.append("syscalls") }
    if resolution.profile.images.requireSignature { gaps.append("images.runtime-signature-enforcement") }
    if !resolution.profile.extensionGrants.isEmpty { gaps.append("extensionGrants") }
    guard gaps.isEmpty else {
      throw WorkloadProfilePolicyError.unsupportedCapabilities(Array(Set(gaps)).sorted())
    }
  }

  public func validateWorkload(
    _ service: DesiredRuntimeService, resolution: WorkloadProfileResolution,
    snapshot: RuntimeCapabilitySnapshot
  ) throws {
    try validateProvider(resolution, snapshot: snapshot)
    let profile = resolution.profile
    var violations: [String] = []
    if profile.filesystem.readOnlyRoot && !service.readOnlyRootFilesystem {
      violations.append("filesystem.readOnlyRoot")
    }
    if let limit = profile.resources?.cpu, (service.cpuCount ?? Int.max) > limit {
      violations.append("resources.cpu")
    }
    if let limit = profile.resources?.memoryMiB {
      let bytes = UInt64(limit) * 1_024 * 1_024
      if (service.memoryBytes ?? UInt64.max) > bytes { violations.append("resources.memoryMiB") }
    }
    if let identity = profile.identity {
      if let user = identity.runAsUser, service.userID != user { violations.append("identity.runAsUser") }
      if let group = identity.runAsGroup, service.groupID != group { violations.append("identity.runAsGroup") }
      if !identity.allowRoot && (service.userID == nil || service.userID == 0) {
        violations.append("identity.allowRoot")
      }
    }
    if profile.images.requireDigest && service.imageLock == nil { violations.append("images.requireDigest") }
    if !profile.hostAccess.allowed && !service.hostAccess.isEmpty { violations.append("hostAccess.allowed") }
    if profile.filesystem.denyHostRoot && service.mounts.contains(where: { $0.source == "/" }) {
      violations.append("filesystem.denyHostRoot")
    }
    if profile.network.mode == .isolated && (!service.networks.isEmpty || service.networkPolicy != nil) {
      violations.append("network.mode")
    }
    let references = Set(service.environment.compactMap { $0.secretReference?.rawValue })
    if !references.isSubset(of: Set(profile.secrets.allowedReferences)) {
      violations.append("secrets.allowedReferences")
    }
    let deniedOptions = Set(profile.runtime.deniedOptions)
    if deniedOptions.contains("init") && service.initProcess { violations.append("runtime.init") }
    if deniedOptions.contains("rosetta") && service.rosetta { violations.append("runtime.rosetta") }
    if deniedOptions.contains("virtualization") && service.virtualization {
      violations.append("runtime.virtualization")
    }
    if deniedOptions.contains("shared-memory") && service.sharedMemoryBytes != nil {
      violations.append("runtime.shared-memory")
    }
    guard violations.isEmpty else {
      throw WorkloadProfilePolicyError.workloadViolation(Array(Set(violations)).sorted())
    }
  }

  public func drift(
    id: String, observedProfileSHA256: String?, observedReasons: [String] = []
  ) throws -> WorkloadProfileDrift {
    let resolution = try resolve(id: id)
    return WorkloadProfileDrift(
      profileIdentifier: id, expectedProfileSHA256: resolution.profileSHA256,
      observedProfileSHA256: observedProfileSHA256,
      reasons: Array(Set(observedReasons)).sorted())
  }

  public static func materialized(
    child: WorkloadProfile, parent: WorkloadProfile
  ) -> WorkloadProfile {
    WorkloadProfile(
      identifier: child.identifier, parent: child.parent, filesystem: child.filesystem,
      network: child.network, resources: child.resources ?? parent.resources,
      identity: child.identity ?? parent.identity, secrets: child.secrets, images: child.images,
      runtime: child.runtime, hostAccess: child.hostAccess, observability: child.observability,
      accelerators: child.accelerators, syscalls: child.syscalls,
      extensionGrants: child.extensionGrants)
  }

  private static func resolutionDigest(
    profile: WorkloadProfile, sourceDigests: [String]
  ) throws -> String {
    let value: ControlPlaneJSONValue = .object([
      "profile": try JSONDecoder().decode(
        ControlPlaneJSONValue.self, from: ControlPlaneCanonicalJSON.encode(profile)),
      "sourceDigests": .array(sourceDigests.map(ControlPlaneJSONValue.string)),
    ])
    return SHA256.hash(data: try ControlPlaneCanonicalJSON.encode(value))
      .map { String(format: "%02x", $0) }.joined()
  }

  private static func compareLimit(
    _ candidate: Int?, _ base: Int?, _ reason: String, into reasons: inout [String]
  ) {
    if let base, candidate == nil || candidate! > base { reasons.append(reason) }
  }

  private static func compareIdentity(
    _ candidate: UInt32?, _ base: UInt32?, _ reason: String, into reasons: inout [String]
  ) {
    if let base, candidate != base { reasons.append(reason) }
  }
}
