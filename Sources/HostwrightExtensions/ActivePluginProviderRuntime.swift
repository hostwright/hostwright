import Foundation
import HostwrightControlPlane
import HostwrightState
import HostwrightWASIProviderRuntime
import HostwrightXPCProvider

public enum ActivePluginProviderRuntimeError: Error, Equatable, Sendable {
  case inactive
  case invalidInvocation
  case missingGrant
  case providerMismatch
  case revoked
  case timedOut
  case executionFailed
}

/// Resolves every invocation through the durable active-digest pointer before
/// executing package-owned code. It never accepts a caller-supplied package path.
public final class ActivePluginProviderRuntime: @unchecked Sendable {
  private let repository: PluginLifecycleRepository
  private let executeWASI: @Sendable (WASIProviderExecution) async throws -> PluginResult
  private let proveXPC: @Sendable (String, Int) async throws -> CodeIdentityProof
  private let lock = NSLock()
  private var revokedDigests = Set<String>()
  private var activeInvocations: [String: [UUID: @Sendable () -> Void]] = [:]

  public init(
    repository: PluginLifecycleRepository,
    wasiWorkerExecutableURL: URL? = nil,
    wasiOwnershipLedgerURL: URL? = nil,
    xpcServiceName: String = XPCServiceContract.serviceIdentifier
  ) throws {
    self.repository = repository
    executeWASI = { request in
      let executor = try WASIProviderHostExecutor(
        workerExecutableURL: wasiWorkerExecutableURL,
        ownershipLedgerURL: wasiOwnershipLedgerURL)
      return try await executor.execute(request)
    }
    _ = try XPCProviderClient(serviceName: xpcServiceName)
    proveXPC = { _, timeout in
      let client = try XPCProviderClient(serviceName: xpcServiceName)
      let response = try await client.execute(XPCRequest(
        requestID: "active-proof:\(UUID().uuidString.lowercased())",
        operation: .codeIdentityProof, timeoutMilliseconds: timeout))
      guard response.status == .completed, let proof = response.proof else {
        throw ActivePluginProviderRuntimeError.executionFailed
      }
      return proof
    }
  }

  init(
    repository: PluginLifecycleRepository,
    wasiExecution: @escaping @Sendable (WASIProviderExecution) async throws -> PluginResult,
    xpcProof: @escaping @Sendable (String, Int) async throws -> CodeIdentityProof
  ) {
    self.repository = repository
    executeWASI = wasiExecution
    proveXPC = xpcProof
  }

  public func invoke(_ invocation: PluginInvocation) async throws -> PluginResult {
    do { try invocation.validate() }
    catch { throw ActivePluginProviderRuntimeError.invalidInvocation }
    let package = try activePackage(identifier: invocation.pluginIdentifier)
    guard package.manifest.providerKind == .wasi else {
      throw ActivePluginProviderRuntimeError.providerMismatch
    }
    guard package.manifest.grants.contains(where: { grant in
      grant.capability == invocation.capability
        && Self.scope(invocation.input) == grant.scope
    }) else { throw ActivePluginProviderRuntimeError.missingGrant }
    let execution = WASIProviderExecution(
      moduleURL: URL(fileURLWithPath: package.storagePath, isDirectory: true)
        .appendingPathComponent(package.manifest.entrypoint),
      expectedModuleDigest: package.manifest.artifactDigest,
      invocation: invocation, grants: package.manifest.grants)
    let task = Task { [executeWASI] in
      try Task.checkCancellation()
      return try await executeWASI(execution)
    }
    let invocationID = UUID()
    let revokedDuringRegistration = register(
      packageDigest: package.packageDigest, invocationID: invocationID,
      cancellation: { task.cancel() })
    if revokedDuringRegistration { task.cancel() }
    defer { unregister(packageDigest: package.packageDigest, invocationID: invocationID) }
    do {
      let result = try await task.value
      guard !isRevoked(package.packageDigest) else {
        throw ActivePluginProviderRuntimeError.revoked
      }
      return result
    } catch let error as ActivePluginProviderRuntimeError { throw error }
    catch is CancellationError {
      throw isRevoked(package.packageDigest)
        ? ActivePluginProviderRuntimeError.revoked : ActivePluginProviderRuntimeError.executionFailed
    } catch WASIProviderRuntimeError.cancelled {
      throw isRevoked(package.packageDigest)
        ? ActivePluginProviderRuntimeError.revoked : ActivePluginProviderRuntimeError.executionFailed
    }
    catch { throw ActivePluginProviderRuntimeError.executionFailed }
  }

  public func proveActiveXPCIdentity(
    identifier: String, timeoutMilliseconds: Int = 5_000
  ) async throws -> CodeIdentityProof {
    guard (100...5_000).contains(timeoutMilliseconds) else {
      throw ActivePluginProviderRuntimeError.invalidInvocation
    }
    let package = try activePackage(identifier: identifier)
    guard package.manifest.providerKind == .xpc else {
      throw ActivePluginProviderRuntimeError.providerMismatch
    }
    let task = Task { [proveXPC] in
      try Task.checkCancellation()
      return try await proveXPC(package.packageDigest, timeoutMilliseconds)
    }
    let invocationID = UUID()
    let revokedDuringRegistration = register(
      packageDigest: package.packageDigest, invocationID: invocationID,
      cancellation: { task.cancel() })
    if revokedDuringRegistration { task.cancel() }
    defer { unregister(packageDigest: package.packageDigest, invocationID: invocationID) }
    do {
      let installed = try XPCProviderCodeIdentity.file(
        URL(fileURLWithPath: package.storagePath, isDirectory: true)
          .appendingPathComponent(package.manifest.entrypoint))
      let live = try await task.value
      guard !isRevoked(package.packageDigest) else {
        throw ActivePluginProviderRuntimeError.revoked
      }
      guard live == installed else { throw ActivePluginProviderRuntimeError.providerMismatch }
      return live
    } catch let error as ActivePluginProviderRuntimeError { throw error }
    catch is CancellationError {
      throw isRevoked(package.packageDigest)
        ? ActivePluginProviderRuntimeError.revoked : ActivePluginProviderRuntimeError.executionFailed
    } catch XPCProviderError.revoked {
      throw ActivePluginProviderRuntimeError.revoked
    }
    catch { throw ActivePluginProviderRuntimeError.executionFailed }
  }

  /// Re-resolves the durable active pointer and exercises the exact activated
  /// provider before the control operation reports activation success.
  public func checkActive(identifier: String, timeoutMilliseconds: Int = 5_000) throws {
    guard (100...5_000).contains(timeoutMilliseconds) else {
      throw ActivePluginProviderRuntimeError.invalidInvocation
    }
    let package = try activePackage(identifier: identifier)
    let completion = ActivePluginCheckCompletion()
    let task = Task.detached { [weak self] in
      guard let self else {
        completion.resolve(.failure(ActivePluginProviderRuntimeError.executionFailed))
        return
      }
      do {
        switch package.manifest.providerKind {
        case .wasi:
          guard let grant = package.manifest.grants.first else {
            throw ActivePluginProviderRuntimeError.missingGrant
          }
          let result = try await self.invoke(PluginInvocation(
            invocationID: "active-health:\(UUID().uuidString.lowercased())",
            pluginIdentifier: package.manifest.identifier,
            capability: grant.capability,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), seed: 0,
            input: .object([
              "operation": .string("health-check"),
              "scope": .string(grant.scope),
            ]),
            limits: WASILimits(
              moduleBytes: WASILimits.default.moduleBytes,
              inputBytes: WASILimits.default.inputBytes,
              outputBytes: WASILimits.default.outputBytes,
              memoryBytes: WASILimits.default.memoryBytes,
              normalExecutionMilliseconds: timeoutMilliseconds,
              absoluteExecutionMilliseconds: min(30_000, max(timeoutMilliseconds, 5_000)))))
          guard result.actions.isEmpty, result.diagnostics.isEmpty else {
            throw ActivePluginProviderRuntimeError.executionFailed
          }
        case .xpc:
          _ = try await self.proveActiveXPCIdentity(
            identifier: package.manifest.identifier,
            timeoutMilliseconds: timeoutMilliseconds)
        }
        completion.resolve(.success(()))
      } catch {
        completion.resolve(.failure(error))
      }
    }
    guard completion.wait(milliseconds: timeoutMilliseconds + 250) else {
      task.cancel()
      throw ActivePluginProviderRuntimeError.timedOut
    }
    try completion.result()
  }

  public func revoke(packageDigest: String) {
    let cancellations = lock.withLock { () -> [@Sendable () -> Void] in
      revokedDigests.insert(packageDigest)
      return activeInvocations.removeValue(forKey: packageDigest).map {
        Array($0.values)
      } ?? []
    }
    cancellations.forEach { $0() }
  }

  private func activePackage(identifier: String) throws -> PluginPackageRecord {
    guard let activation = try repository.activation(identifier: identifier),
      let package = try repository.package(digest: activation.activePackageDigest)
    else { throw ActivePluginProviderRuntimeError.inactive }
    if isRevoked(package.packageDigest) { throw ActivePluginProviderRuntimeError.revoked }
    guard package.lifecycleState == .active, package.manifest.identifier == identifier else {
      throw ActivePluginProviderRuntimeError.inactive
    }
    return package
  }

  private func register(
    packageDigest: String, invocationID: UUID,
    cancellation: @escaping @Sendable () -> Void
  ) -> Bool {
    lock.withLock {
      activeInvocations[packageDigest, default: [:]][invocationID] = cancellation
      return revokedDigests.contains(packageDigest)
    }
  }

  private func unregister(packageDigest: String, invocationID: UUID) {
    lock.withLock {
      activeInvocations[packageDigest]?[invocationID] = nil
      if activeInvocations[packageDigest]?.isEmpty == true {
        activeInvocations[packageDigest] = nil
      }
    }
  }

  private func isRevoked(_ packageDigest: String) -> Bool {
    lock.withLock { revokedDigests.contains(packageDigest) }
  }

  private static func scope(_ input: ControlPlaneJSONValue) -> String? {
    guard case .object(let fields) = input, case .string(let scope)? = fields["scope"] else {
      return nil
    }
    return scope
  }
}

private final class ActivePluginCheckCompletion: @unchecked Sendable {
  private let condition = NSCondition()
  private var outcome: Result<Void, Error>?

  func resolve(_ result: Result<Void, Error>) {
    condition.lock()
    if outcome == nil { outcome = result }
    condition.broadcast()
    condition.unlock()
  }

  func wait(milliseconds: Int) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(Double(milliseconds) / 1_000)
    while outcome == nil {
      if !condition.wait(until: deadline) { return outcome != nil }
    }
    return true
  }

  func result() throws {
    condition.lock()
    let result = outcome
    condition.unlock()
    guard let result else { throw ActivePluginProviderRuntimeError.timedOut }
    try result.get()
  }
}
