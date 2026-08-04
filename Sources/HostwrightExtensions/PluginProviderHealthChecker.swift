import Foundation
import HostwrightControlPlane
import HostwrightState
import HostwrightWASIProviderRuntime
import HostwrightXPCProvider

public enum PluginProviderHealthError: Error, Equatable, Sendable {
  case invalidPackage
  case failed
  case timedOut
  case revoked
}

public final class PluginProviderHealthChecker: @unchecked Sendable {
  private let executeWASI: @Sendable (WASIProviderExecution) async throws -> PluginResult
  private let xpcServiceName: String
  private let lock = NSLock()
  private var revokedDigests = Set<String>()
  private var xpcClients: [String: XPCProviderClient] = [:]
  private var activeChecks: [String: [UUID: Task<Void, Never>]] = [:]

  public init(
    wasiWorkerExecutableURL: URL? = nil, wasiOwnershipLedgerURL: URL? = nil,
    xpcServiceName: String = XPCServiceContract.serviceIdentifier
  ) throws {
    executeWASI = { request in
      let executor = try WASIProviderHostExecutor(
        workerExecutableURL: wasiWorkerExecutableURL,
        ownershipLedgerURL: wasiOwnershipLedgerURL)
      return try await executor.execute(request)
    }
    _ = try XPCProviderClient(serviceName: xpcServiceName)
    self.xpcServiceName = xpcServiceName
  }

  init(
    wasiExecution: @escaping @Sendable (WASIProviderExecution) async throws -> PluginResult,
    xpcServiceName: String = XPCServiceContract.serviceIdentifier
  ) throws {
    executeWASI = wasiExecution
    _ = try XPCProviderClient(serviceName: xpcServiceName)
    self.xpcServiceName = xpcServiceName
  }

  public func check(_ package: PluginPackageRecord, timeoutMilliseconds: Int = 5_000) throws {
    guard package.lifecycleState == .staged || package.lifecycleState == .rollback,
      !package.manifest.grants.isEmpty, (100...5_000).contains(timeoutMilliseconds),
      !lock.withLock({ revokedDigests.contains(package.packageDigest) })
    else { throw PluginProviderHealthError.invalidPackage }
    let completion = PluginProviderHealthCompletion()
    let xpcClient: XPCProviderClient?
    if package.manifest.providerKind == .xpc {
      xpcClient = try lock.withLock {
        if let existing = xpcClients[package.packageDigest] { return existing }
        let created = try XPCProviderClient(serviceName: xpcServiceName)
        xpcClients[package.packageDigest] = created
        return created
      }
    } else {
      xpcClient = nil
    }
    let checkID = UUID()
    let task = Task.detached { [executeWASI] in
      do {
        try Task.checkCancellation()
        switch package.manifest.providerKind {
        case .wasi:
          guard let grant = package.manifest.grants.first else {
            throw PluginProviderHealthError.invalidPackage
          }
          let invocation = PluginInvocation(
            invocationID: "health:\(UUID().uuidString.lowercased())",
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
              absoluteExecutionMilliseconds: min(30_000, max(timeoutMilliseconds, 5_000))))
          let result = try await executeWASI(WASIProviderExecution(
            moduleURL: URL(fileURLWithPath: package.storagePath, isDirectory: true)
              .appendingPathComponent(package.manifest.entrypoint),
            expectedModuleDigest: package.manifest.artifactDigest,
            invocation: invocation, grants: package.manifest.grants))
          guard result.actions.isEmpty, result.diagnostics.isEmpty else {
            throw PluginProviderHealthError.failed
          }
        case .xpc:
          guard let xpcClient else { throw PluginProviderHealthError.failed }
          let installedProof = try XPCProviderCodeIdentity.file(
            URL(fileURLWithPath: package.storagePath, isDirectory: true)
              .appendingPathComponent(package.manifest.entrypoint))
          let request = XPCRequest(
            requestID: "health:\(UUID().uuidString.lowercased())",
            operation: .codeIdentityProof, timeoutMilliseconds: timeoutMilliseconds)
          let response = try await xpcClient.execute(request)
          guard response.status == .completed, response.proof == installedProof else {
            throw PluginProviderHealthError.failed
          }
        }
        completion.resolve(.success(()))
      } catch {
        completion.resolve(.failure(error))
      }
    }
    let revokedDuringRegistration = lock.withLock { () -> Bool in
      activeChecks[package.packageDigest, default: [:]][checkID] = task
      return revokedDigests.contains(package.packageDigest)
    }
    if revokedDuringRegistration { task.cancel() }
    defer {
      lock.withLock {
        activeChecks[package.packageDigest]?[checkID] = nil
        if activeChecks[package.packageDigest]?.isEmpty == true {
          activeChecks[package.packageDigest] = nil
        }
      }
    }
    guard completion.wait(milliseconds: timeoutMilliseconds + 250) else {
      task.cancel()
      throw PluginProviderHealthError.timedOut
    }
    do { try completion.result() }
    catch WASIProviderRuntimeError.timedOut { throw PluginProviderHealthError.timedOut }
    catch XPCProviderError.timedOut { throw PluginProviderHealthError.timedOut }
    catch XPCProviderError.revoked { throw PluginProviderHealthError.revoked }
    catch is CancellationError { throw PluginProviderHealthError.revoked }
    catch WASIProviderRuntimeError.cancelled {
      if lock.withLock({ revokedDigests.contains(package.packageDigest) }) {
        throw PluginProviderHealthError.revoked
      }
      throw PluginProviderHealthError.failed
    }
    catch let error as PluginProviderHealthError { throw error }
    catch { throw PluginProviderHealthError.failed }
  }

  public func revoke(packageDigest: String) {
    let (client, tasks) = lock.withLock { () -> (XPCProviderClient?, [Task<Void, Never>]) in
      revokedDigests.insert(packageDigest)
      return (
        xpcClients.removeValue(forKey: packageDigest),
        activeChecks.removeValue(forKey: packageDigest).map { Array($0.values) } ?? []
      )
    }
    client?.revoke()
    tasks.forEach { $0.cancel() }
  }
}

private final class PluginProviderHealthCompletion: @unchecked Sendable {
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
    guard let result else { throw PluginProviderHealthError.timedOut }
    try result.get()
  }
}
