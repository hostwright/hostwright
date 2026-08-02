import Foundation

public struct FilesystemProfile: Codable, Equatable, Sendable {
  public let readOnlyRoot: Bool
  public let allowReadPaths: [String]
  public let allowWritePaths: [String]
  public let denyHostRoot: Bool
  public init(
    readOnlyRoot: Bool, allowReadPaths: [String] = [], allowWritePaths: [String] = [],
    denyHostRoot: Bool
  ) {
    self.readOnlyRoot = readOnlyRoot
    self.allowReadPaths = allowReadPaths
    self.allowWritePaths = allowWritePaths
    self.denyHostRoot = denyHostRoot
  }
}
public enum NetworkProfileMode: String, Codable, CaseIterable, Sendable { case isolated, brokered }
public struct NetworkProfile: Codable, Equatable, Sendable {
  public let mode: NetworkProfileMode
  public let allowedOrigins: [String]
  public init(mode: NetworkProfileMode, allowedOrigins: [String] = []) {
    self.mode = mode
    self.allowedOrigins = allowedOrigins
  }
}
public struct ResourceProfile: Codable, Equatable, Sendable {
  public let cpu: Int?
  public let memoryMiB: Int?
  public let processCount: Int?
  public init(cpu: Int? = nil, memoryMiB: Int? = nil, processCount: Int? = nil) {
    self.cpu = cpu
    self.memoryMiB = memoryMiB
    self.processCount = processCount
  }
  public func validate() throws {
    guard [cpu, memoryMiB, processCount].allSatisfy({ $0 == nil || $0! > 0 }) else {
      throw ContractValidationError.outOfBounds("profile resources")
    }
  }
}
public struct IdentityProfile: Codable, Equatable, Sendable {
  public let runAsUser: UInt32?
  public let runAsGroup: UInt32?
  public let allowRoot: Bool
  public init(runAsUser: UInt32? = nil, runAsGroup: UInt32? = nil, allowRoot: Bool = false) {
    self.runAsUser = runAsUser
    self.runAsGroup = runAsGroup
    self.allowRoot = allowRoot
  }
}
public struct SecretsProfile: Codable, Equatable, Sendable {
  public let allowedReferences: [String]
  public init(allowedReferences: [String] = []) { self.allowedReferences = allowedReferences }
}
public struct ImagesProfile: Codable, Equatable, Sendable {
  public let requireDigest: Bool
  public let requireSignature: Bool
  public init(requireDigest: Bool, requireSignature: Bool) {
    self.requireDigest = requireDigest
    self.requireSignature = requireSignature
  }
}
public struct RuntimeProfile: Codable, Equatable, Sendable {
  public let allowedProviders: [String]
  public let deniedOptions: [String]
  public init(allowedProviders: [String] = [], deniedOptions: [String] = []) {
    self.allowedProviders = allowedProviders
    self.deniedOptions = deniedOptions
  }
}
public struct HostAccessProfile: Codable, Equatable, Sendable {
  public let allowed: Bool
  public init(allowed: Bool) { self.allowed = allowed }
}
public struct ObservabilityProfile: Codable, Equatable, Sendable {
  public let logs: Bool
  public let metrics: Bool
  public let traces: Bool
  public init(logs: Bool, metrics: Bool, traces: Bool) {
    self.logs = logs
    self.metrics = metrics
    self.traces = traces
  }
}
public struct AcceleratorsProfile: Codable, Equatable, Sendable {
  public let allowed: [String]
  public init(allowed: [String] = []) { self.allowed = allowed }
}
public struct SyscallProfile: Codable, Equatable, Sendable {
  public let defaultDeny: Bool
  public let allowed: [String]
  public let denied: [String]
  public init(defaultDeny: Bool, allowed: [String] = [], denied: [String] = []) {
    self.defaultDeny = defaultDeny
    self.allowed = allowed
    self.denied = denied
  }
}

public struct WorkloadProfile: Codable, Equatable, Sendable {
  public let version: Int
  public let identifier: String
  public let parent: String?
  public let filesystem: FilesystemProfile
  public let network: NetworkProfile
  public let resources: ResourceProfile?
  public let identity: IdentityProfile?
  public let secrets: SecretsProfile
  public let images: ImagesProfile
  public let runtime: RuntimeProfile
  public let hostAccess: HostAccessProfile
  public let observability: ObservabilityProfile
  public let accelerators: AcceleratorsProfile
  public let syscalls: SyscallProfile
  public let extensionGrants: [PluginGrant]
  public init(
    version: Int = 1, identifier: String, parent: String? = nil, filesystem: FilesystemProfile,
    network: NetworkProfile, resources: ResourceProfile? = nil, identity: IdentityProfile? = nil,
    secrets: SecretsProfile, images: ImagesProfile, runtime: RuntimeProfile,
    hostAccess: HostAccessProfile, observability: ObservabilityProfile,
    accelerators: AcceleratorsProfile, syscalls: SyscallProfile, extensionGrants: [PluginGrant] = []
  ) {
    self.version = version
    self.identifier = identifier
    self.parent = parent
    self.filesystem = filesystem
    self.network = network
    self.resources = resources
    self.identity = identity
    self.secrets = secrets
    self.images = images
    self.runtime = runtime
    self.hostAccess = hostAccess
    self.observability = observability
    self.accelerators = accelerators
    self.syscalls = syscalls
    self.extensionGrants = extensionGrants
  }
  public func validate() throws {
    guard version == 1 else { throw ContractValidationError.unsupportedVersion("workload profile") }
    guard !identifier.isEmpty && parent != identifier else {
      throw ContractValidationError.invalid("profile parent")
    }
    try resources?.validate()
    try extensionGrants.forEach { try $0.validate() }
  }
}

public struct WASILimits: Codable, Equatable, Sendable {
  public let moduleBytes: Int
  public let inputBytes: Int
  public let outputBytes: Int
  public let memoryBytes: Int
  public let normalExecutionMilliseconds: Int
  public let absoluteExecutionMilliseconds: Int
  public static let `default` = WASILimits(
    moduleBytes: 16 * 1_024 * 1_024, inputBytes: 1_024 * 1_024, outputBytes: 1_024 * 1_024,
    memoryBytes: 64 * 1_024 * 1_024, normalExecutionMilliseconds: 5_000,
    absoluteExecutionMilliseconds: 30_000)
  public init(
    moduleBytes: Int, inputBytes: Int, outputBytes: Int, memoryBytes: Int,
    normalExecutionMilliseconds: Int, absoluteExecutionMilliseconds: Int
  ) {
    self.moduleBytes = moduleBytes
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
    self.memoryBytes = memoryBytes
    self.normalExecutionMilliseconds = normalExecutionMilliseconds
    self.absoluteExecutionMilliseconds = absoluteExecutionMilliseconds
  }
  public func validate() throws {
    let max = Self.default
    guard
      moduleBytes > 0 && moduleBytes <= max.moduleBytes && inputBytes > 0
        && inputBytes <= max.inputBytes && outputBytes > 0 && outputBytes <= max.outputBytes
        && memoryBytes > 0 && memoryBytes <= max.memoryBytes && normalExecutionMilliseconds > 0
        && normalExecutionMilliseconds <= max.normalExecutionMilliseconds
        && absoluteExecutionMilliseconds >= normalExecutionMilliseconds
        && absoluteExecutionMilliseconds <= max.absoluteExecutionMilliseconds
    else { throw ContractValidationError.outOfBounds("WASI limits") }
  }
}
public enum PluginCapability: String, Codable, CaseIterable, Sendable {
  case policy, observation, storage, network, diagnostics, scheduler
  case secretMetadata = "secret-metadata"
}
public struct PluginGrant: Codable, Equatable, Sendable {
  public let capability: PluginCapability
  public let scope: String
  public init(capability: PluginCapability, scope: String) {
    self.capability = capability
    self.scope = scope
  }
  public func validate() throws {
    guard !scope.isEmpty else { throw ContractValidationError.required("plugin grant scope") }
  }
}
public enum PluginProviderKind: String, Codable, CaseIterable, Sendable { case wasi, xpc }
public struct PluginInvocation: Codable, Equatable, Sendable {
  public let invocationID: String
  public let pluginIdentifier: String
  public let capability: PluginCapability
  public let timestamp: Date
  public let seed: UInt64
  public let input: ControlPlaneJSONValue
  public let limits: WASILimits
  public init(
    invocationID: String, pluginIdentifier: String, capability: PluginCapability, timestamp: Date,
    seed: UInt64, input: ControlPlaneJSONValue, limits: WASILimits = .default
  ) {
    self.invocationID = invocationID
    self.pluginIdentifier = pluginIdentifier
    self.capability = capability
    self.timestamp = timestamp
    self.seed = seed
    self.input = input
    self.limits = limits
  }
  public func validate() throws {
    guard !invocationID.isEmpty && !pluginIdentifier.isEmpty else {
      throw ContractValidationError.required("plugin invocation")
    }
    try limits.validate()
  }
}
public struct PluginProposedAction: Codable, Equatable, Sendable {
  public let capability: PluginCapability
  public let kind: String
  public let payload: ControlPlaneJSONValue
  public init(capability: PluginCapability, kind: String, payload: ControlPlaneJSONValue) {
    self.capability = capability
    self.kind = kind
    self.payload = payload
  }
}
public struct PluginResult: Codable, Equatable, Sendable {
  public let invocationID: String
  public let actions: [PluginProposedAction]
  public let diagnostics: [SanitizedError]
  public init(
    invocationID: String, actions: [PluginProposedAction] = [], diagnostics: [SanitizedError] = []
  ) {
    self.invocationID = invocationID
    self.actions = actions
    self.diagnostics = diagnostics
  }
}
public struct PluginContentDigest: Codable, Equatable, Sendable {
  public let path: String
  public let digest: String
  public init(path: String, digest: String) {
    self.path = path
    self.digest = digest
  }
  public func validate() throws {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(".."), AuditRecord.digest(digest)
    else { throw ContractValidationError.invalid("plugin content digest") }
  }
}
public struct PluginPackageManifest: Codable, Equatable, Sendable {
  public let abiVersion: Int
  public let identifier: String
  public let packageVersion: String
  public let hostwrightCompatibility: String
  public let providerKind: PluginProviderKind
  public let entrypoint: String
  public let grants: [PluginGrant]
  public let artifactDigest: String
  public let contentDigests: [PluginContentDigest]
  public let provenance: PluginProvenance
  public let cmsSignature: String
  public let signerIdentifier: String
  public init(
    abiVersion: Int = 1, identifier: String, packageVersion: String,
    hostwrightCompatibility: String, providerKind: PluginProviderKind, entrypoint: String,
    grants: [PluginGrant], artifactDigest: String, contentDigests: [PluginContentDigest],
    provenance: PluginProvenance, cmsSignature: String, signerIdentifier: String
  ) {
    self.abiVersion = abiVersion
    self.identifier = identifier
    self.packageVersion = packageVersion
    self.hostwrightCompatibility = hostwrightCompatibility
    self.providerKind = providerKind
    self.entrypoint = entrypoint
    self.grants = grants
    self.artifactDigest = artifactDigest
    self.contentDigests = contentDigests
    self.provenance = provenance
    self.cmsSignature = cmsSignature
    self.signerIdentifier = signerIdentifier
  }
  public func validate() throws {
    guard abiVersion == 1 else { throw ContractValidationError.unsupportedVersion("plugin ABI") }
    guard
      !identifier.isEmpty && !packageVersion.isEmpty && !hostwrightCompatibility.isEmpty
        && !entrypoint.isEmpty && AuditRecord.digest(artifactDigest) && !contentDigests.isEmpty
        && Set(contentDigests.map(\.path)).count == contentDigests.count && !cmsSignature.isEmpty
        && !signerIdentifier.isEmpty
    else { throw ContractValidationError.required("plugin manifest") }
    try grants.forEach { try $0.validate() }
    try contentDigests.forEach { try $0.validate() }
    try provenance.validate()
  }
}
public enum PluginSourceKind: String, Codable, Sendable { case localDirectory, httpsRegistry }
public struct PluginSource: Codable, Equatable, Sendable {
  public let kind: PluginSourceKind
  public let locator: String

  public func validate() throws {
    switch kind {
    case .localDirectory:
      guard locator.hasPrefix("/"), !locator.contains("/../"), !locator.hasSuffix("/..") else {
        throw ContractValidationError.invalid("local plugin source")
      }
    case .httpsRegistry:
      guard let url = URL(string: locator), url.scheme == "https", url.host?.isEmpty == false else {
        throw ContractValidationError.invalid("HTTPS plugin source")
      }
    }
  }
}
public enum WASISandboxContract {
  public static let preopens: [String] = []
  public static let inheritedEnvironment: [String] = []
  public static let ambientNetwork = false
  public static let hostSocketAccess = false
  public static let stateDatabaseAccess = false
  public static let keychainAccess = false
  public static let runtimeAccess = false
  public static let previewVersion = "Preview1"
  public static let commandEnabled = true
  public static let stdinMaximumBytes = 1_048_576
  public static let stdoutMaximumBytes = 1_048_576
  public static let stderrMaximumBytes = 1_048_576
  public static let freshInstancePerInvocation = true
}
public struct PluginProvenance: Codable, Equatable, Sendable {
  public let checksum: String
  public let signature: String
  public let signerIdentifier: String
  public let source: PluginSource
  public init(checksum: String, signature: String, signerIdentifier: String, source: PluginSource) {
    self.checksum = checksum
    self.signature = signature
    self.signerIdentifier = signerIdentifier
    self.source = source
  }
  public func validate() throws {
    guard AuditRecord.digest(checksum), !signature.isEmpty, !signerIdentifier.isEmpty,
      !source.locator.isEmpty
    else { throw ContractValidationError.invalid("plugin provenance") }
    try source.validate()
  }
}
public enum PluginLifecycleState: String, Codable, CaseIterable, Sendable {
  case discovered, verified, staged, active, rollback, quarantined, revoked, uninstalled
}
