import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightCore
import HostwrightExtensions
import HostwrightRegistry
import HostwrightState

struct PluginControlRuntime: @unchecked Sendable {
  let repository: PluginLifecycleRepository
  let immutableStore: PluginImmutableStore
  let healthCheck: @Sendable (PluginPackageRecord, Int) throws -> Void
  let activeHealthCheck: @Sendable (String, Int) throws -> Void
  let revokeProvider: @Sendable (String) -> Void
  let httpsMaterializer: HTTPSPluginPackageSourceMaterializer
  let trustedSignerCertificates: [String: [Data]]

  init(
    repository: PluginLifecycleRepository, immutableStore: PluginImmutableStore,
    healthChecker: PluginProviderHealthChecker,
    registryTransport: any RegistrySynchronousHTTPTransporting,
    activeProviders: ActivePluginProviderRuntime,
    trustedSignerCertificates: [String: [Data]]
  ) {
    self.repository = repository
    self.immutableStore = immutableStore
    healthCheck = { try healthChecker.check($0, timeoutMilliseconds: $1) }
    activeHealthCheck = {
      try activeProviders.checkActive(identifier: $0, timeoutMilliseconds: $1)
    }
    revokeProvider = {
      healthChecker.revoke(packageDigest: $0)
      activeProviders.revoke(packageDigest: $0)
    }
    httpsMaterializer = HTTPSPluginPackageSourceMaterializer(transport: registryTransport)
    self.trustedSignerCertificates = trustedSignerCertificates
  }

  init(
    repository: PluginLifecycleRepository, immutableStore: PluginImmutableStore,
    healthCheck: @escaping @Sendable (PluginPackageRecord, Int) throws -> Void,
    activeHealthCheck: @escaping @Sendable (String, Int) throws -> Void = { _, _ in },
    revokeProvider: @escaping @Sendable (String) -> Void,
    httpsMaterializer: HTTPSPluginPackageSourceMaterializer = HTTPSPluginPackageSourceMaterializer(),
    trustedSignerCertificates: [String: [Data]] = [:]
  ) {
    self.repository = repository
    self.immutableStore = immutableStore
    self.healthCheck = healthCheck
    self.activeHealthCheck = activeHealthCheck
    self.revokeProvider = revokeProvider
    self.httpsMaterializer = httpsMaterializer
    self.trustedSignerCertificates = trustedSignerCertificates
  }
}

enum PluginControlOperations {
  static let mutatingOperations: Set<String> = [
    "plugin.install", "plugin.update", "plugin.activate", "plugin.rollback",
    "plugin.revoke", "plugin.quarantine", "plugin.uninstall",
  ]

  static func handle(
    peer: AuthenticatedControlPeer, request: ControlRequestEnvelope,
    runtime: PluginControlRuntime, now: Date = Date()
  ) -> ControlResponseEnvelope? {
    guard request.operation.hasPrefix("plugin.") else { return nil }
    do {
      let fields = try bodyFields(request.body)
      let subjectID = peer.binding.subject.identifier
      let timestamp = ISO8601DateFormatter().string(from: now)
      let result: ControlPlaneJSONValue
      switch request.operation {
      case "plugin.list":
        try requireExactKeys(fields, allowed: ["identifier"])
        result = try value(runtime.repository.listPackages(
          identifier: try optionalString("identifier", from: fields)))
      case "plugin.get", "plugin.status":
        try requireExactKeys(fields, allowed: ["packageDigest", "identifier"])
        let digest = try optionalDigest("packageDigest", from: fields)
        let identifier = try optionalString("identifier", from: fields)
        guard (digest == nil) != (identifier == nil) else {
          throw PluginControlError.invalidRequest
        }
        if let digest {
          guard let package = try runtime.repository.package(digest: digest) else {
            throw PluginControlError.notFound
          }
          result = try value(package)
        } else if let identifier {
          result = try value(PluginStatusResult(
            packages: runtime.repository.listPackages(identifier: identifier),
            activation: runtime.repository.activation(identifier: identifier)))
        } else {
          throw PluginControlError.invalidRequest
        }
      case "plugin.discover":
        try requireExactKeys(
          fields,
          allowed: ["source", "trustedSignerIdentifier"])
        result = try withVerifiedPackage(fields: fields, runtime: runtime) { verified in
          try value(PluginDiscoveryResult(
            manifest: verified.manifest, packageDigest: verified.packageDigest))
        }
      case "plugin.install", "plugin.update":
        try requireExactKeys(
          fields,
          allowed: ["source", "trustedSignerIdentifier"])
        guard let idempotencyKey = request.idempotencyKey, !idempotencyKey.isEmpty else {
          throw PluginControlError.idempotencyRequired
        }
        result = try withVerifiedPackage(fields: fields, runtime: runtime) { verified in
          let existing = try runtime.repository.listPackages(
            identifier: verified.manifest.identifier)
          guard request.operation == "plugin.install" ? existing.isEmpty : !existing.isEmpty else {
            throw PluginControlError.lifecycleConflict
          }
          if request.operation == "plugin.update" {
            let proposed = try PluginCompatibilityRange.Version(
              verified.manifest.packageVersion)
            guard try existing.allSatisfy({
              try PluginCompatibilityRange.Version($0.manifest.packageVersion) < proposed
            }) else { throw PluginControlError.lifecycleConflict }
          }
          return try value(runtime.immutableStore.install(
            verified: verified,
            request: PluginInstallRequest(
              operationID: request.requestID, idempotencyKey: idempotencyKey,
              actorSubjectID: subjectID, timestamp: timestamp),
            repository: runtime.repository))
        }
      case "plugin.activate":
        try requireExactKeys(
          fields, allowed: ["packageDigest", "expectedActivationGeneration"])
        let digest = try requiredDigest("packageDigest", from: fields)
        guard let package = try runtime.repository.package(digest: digest) else {
          throw PluginControlError.notFound
        }
        try runtime.healthCheck(package, min(request.timeoutMilliseconds ?? 5_000, 5_000))
        let timeout = min(request.timeoutMilliseconds ?? 5_000, 5_000)
        let activated = try runtime.repository.activate(
          digest: digest,
          expectedActivationGeneration: try optionalInt(
            "expectedActivationGeneration", from: fields),
          actorSubjectID: subjectID, timestamp: timestamp)
        try verifyActivated(
          activated, packageDigest: digest, requestID: request.requestID,
          timeoutMilliseconds: timeout, subjectID: subjectID, timestamp: timestamp,
          runtime: runtime)
        result = try value(activated)
      case "plugin.rollback":
        try requireExactKeys(fields, allowed: ["identifier", "expectedActivationGeneration"])
        guard let idempotencyKey = request.idempotencyKey, !idempotencyKey.isEmpty else {
          throw PluginControlError.idempotencyRequired
        }
        let identifier = try requiredString("identifier", from: fields)
        guard let activation = try runtime.repository.activation(identifier: identifier),
          let priorDigest = activation.priorPackageDigest,
          let prior = try runtime.repository.package(digest: priorDigest)
        else { throw PluginControlError.notFound }
        let operation = try runtime.repository.beginRollback(PluginRollbackRecord(
          operationID: request.requestID, pluginIdentifier: identifier,
          fromPackageDigest: activation.activePackageDigest, toPackageDigest: priorDigest,
          stage: "rollback-intent", status: "pending", idempotencyKey: idempotencyKey,
          ownershipEffects: prior.ownershipLedger, failureReasonCode: nil,
          requestedBySubjectID: subjectID, generation: 1,
          createdAt: timestamp, updatedAt: timestamp))
        do {
          var current = try runtime.repository.advanceRollback(
            operationID: operation.operationID, expectedGeneration: operation.generation,
            stage: "health-check", status: "running", updatedAt: timestamp)
          try runtime.healthCheck(prior, min(request.timeoutMilliseconds ?? 5_000, 5_000))
          current = try runtime.repository.advanceRollback(
            operationID: current.operationID, expectedGeneration: current.generation,
            stage: "activation", status: "running", updatedAt: timestamp)
          let activated = try runtime.repository.activate(
            digest: priorDigest,
            expectedActivationGeneration: try optionalInt(
              "expectedActivationGeneration", from: fields) ?? activation.generation,
            actorSubjectID: subjectID, timestamp: timestamp)
          try verifyActivated(
            activated, packageDigest: priorDigest, requestID: request.requestID,
            timeoutMilliseconds: min(request.timeoutMilliseconds ?? 5_000, 5_000),
            subjectID: subjectID, timestamp: timestamp, runtime: runtime)
          _ = try runtime.repository.advanceRollback(
            operationID: current.operationID, expectedGeneration: current.generation,
            stage: "complete", status: "succeeded", updatedAt: timestamp)
          result = try value(activated)
        } catch {
          if let current = try? runtime.repository.rollback(operationID: operation.operationID),
            !["succeeded", "failed", "cancelled"].contains(current.status)
          {
            _ = try? runtime.repository.advanceRollback(
              operationID: current.operationID, expectedGeneration: current.generation,
              stage: current.stage, status: "failed",
              failureReasonCode: "plugin.rollback-failed", updatedAt: timestamp)
          }
          throw error
        }
      case "plugin.revoke":
        try requireExactKeys(
          fields, allowed: ["revocationID", "targetKind", "targetIdentifier", "reason"])
        let targetKind = try requiredString("targetKind", from: fields)
        let targetIdentifier = try requiredString(
          "targetIdentifier", from: fields, maximumBytes: 256)
        try runtime.repository.revoke(
          revocationID: try requiredString("revocationID", from: fields),
          targetKind: targetKind, targetIdentifier: targetIdentifier,
          reason: try requiredString("reason", from: fields, maximumBytes: 1_024),
          actorSubjectID: subjectID, timestamp: timestamp)
        if targetKind == "package" { runtime.revokeProvider(targetIdentifier) }
        if targetKind == "signer" {
          for package in try runtime.repository.listPackages()
          where package.manifest.signerIdentifier == targetIdentifier {
            runtime.revokeProvider(package.packageDigest)
          }
        }
        result = .object(["revoked": .bool(true)])
      case "plugin.quarantine":
        try requireExactKeys(
          fields,
          allowed: ["quarantineID", "packageDigest", "reasonCode", "detailDigest"])
        let digest = try requiredDigest("packageDigest", from: fields)
        try runtime.repository.quarantine(
          quarantineID: try requiredString("quarantineID", from: fields),
          packageDigest: digest,
          reasonCode: try requiredString("reasonCode", from: fields),
          detailDigest: try requiredDigest("detailDigest", from: fields),
          actorSubjectID: subjectID, timestamp: timestamp)
        runtime.revokeProvider(digest)
        result = .object(["quarantined": .bool(true)])
      case "plugin.uninstall":
        try requireExactKeys(fields, allowed: ["packageDigest", "expectedGeneration"])
        guard let idempotencyKey = request.idempotencyKey, !idempotencyKey.isEmpty else {
          throw PluginControlError.idempotencyRequired
        }
        let digest = try requiredDigest("packageDigest", from: fields)
        guard let package = try runtime.repository.package(digest: digest) else {
          throw PluginControlError.notFound
        }
        let operation = try runtime.repository.beginRollback(PluginRollbackRecord(
          operationID: request.requestID, pluginIdentifier: package.manifest.identifier,
          fromPackageDigest: nil, toPackageDigest: digest,
          stage: "uninstall-intent", status: "pending", idempotencyKey: idempotencyKey,
          ownershipEffects: package.ownershipLedger, failureReasonCode: nil,
          requestedBySubjectID: subjectID, generation: 1,
          createdAt: timestamp, updatedAt: timestamp))
        do {
          let uninstalled = try runtime.repository.uninstall(
            digest: digest,
            expectedGeneration: try requiredInt("expectedGeneration", from: fields),
            actorSubjectID: subjectID, timestamp: timestamp)
          var current = try runtime.repository.advanceRollback(
            operationID: operation.operationID, expectedGeneration: operation.generation,
            stage: "cleanup", status: "running",
            ownershipEffects: uninstalled.ownershipLedger, updatedAt: timestamp)
          runtime.revokeProvider(digest)
          if FileManager.default.fileExists(atPath: uninstalled.storagePath) {
            try runtime.immutableStore.removeInstalledPackage(uninstalled)
          }
          current = try runtime.repository.advanceRollback(
            operationID: current.operationID, expectedGeneration: current.generation,
            stage: "complete", status: "succeeded", updatedAt: timestamp)
          _ = current
          result = try value(uninstalled)
        } catch {
          if let current = try? runtime.repository.rollback(operationID: operation.operationID),
            !["succeeded", "failed", "cancelled"].contains(current.status)
          {
            _ = try? runtime.repository.advanceRollback(
              operationID: current.operationID, expectedGeneration: current.generation,
              stage: current.stage, status: "failed",
              failureReasonCode: "plugin.uninstall-failed", updatedAt: timestamp)
          }
          throw error
        }
      default:
        return failure(
          requestID: request.requestID, reason: .invalidRequest,
          code: "unsupportedPluginOperation",
          message: "The plugin operation is not supported.")
      }
      return ControlResponseEnvelope(
        requestID: request.requestID, status: .completed,
        reasonCode: .completed, result: result)
    } catch PluginControlError.idempotencyRequired {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "pluginIdempotencyRequired",
        message: "The plugin mutation requires an idempotency key.")
    } catch PluginControlError.notFound {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "pluginNotFound", message: "The requested plugin state was not found.")
    } catch {
      return failure(
        requestID: request.requestID, reason: .invalidRequest,
        code: "invalidPluginRequest",
        message: "The plugin request is invalid or conflicts with current lifecycle state.")
    }
  }

  private static func withVerifiedPackage<T>(
    fields: [String: ControlPlaneJSONValue], runtime: PluginControlRuntime,
    body: (VerifiedPluginPackage) throws -> T
  ) throws -> T {
    guard let sourceValue = fields["source"], case .object(let sourceFields) = sourceValue else {
      throw PluginControlError.invalidRequest
    }
    try requireExactKeys(sourceFields, allowed: ["kind", "locator"])
    let source: PluginSource = try decodeField("source", from: fields)
    let signerIdentifier = try requiredString(
      "trustedSignerIdentifier", from: fields, maximumBytes: 256)
    guard let certificates = runtime.trustedSignerCertificates[signerIdentifier],
      !certificates.isEmpty
    else { throw PluginControlError.invalidRequest }
    let verifier = try PluginPackageVerifier(
      trustedSignerCertificates: [signerIdentifier: certificates],
      hostVersion: String(HostwrightIdentity.releaseTarget.dropFirst()))
    switch source.kind {
    case .localDirectory:
      return try body(verifier.verifyMaterializedPackage(
        at: URL(fileURLWithPath: source.locator, isDirectory: true),
        expectedSource: source))
    case .httpsRegistry:
      let materialized = try runtime.httpsMaterializer.materialize(source: source)
      do {
        let result = try body(verifier.verifyMaterializedPackage(
          at: materialized.directoryURL, expectedSource: source))
        try materialized.cleanup()
        return result
      } catch {
        do { try materialized.cleanup() }
        catch { throw PluginControlError.materializedCleanupFailed }
        throw error
      }
    }
  }

  private static func verifyActivated(
    _ activation: PluginActivationRecord, packageDigest: String, requestID: String,
    timeoutMilliseconds: Int, subjectID: String, timestamp: String,
    runtime: PluginControlRuntime
  ) throws {
    do {
      try runtime.activeHealthCheck(activation.pluginIdentifier, timeoutMilliseconds)
    } catch {
      runtime.revokeProvider(packageDigest)
      let requestDigest = SHA256.hash(data: Data(requestID.utf8)).map {
        String(format: "%02x", $0)
      }.joined()
      let detailDigest = SHA256.hash(
        data: Data("active-health-failed:\(packageDigest)".utf8)
      ).map { String(format: "%02x", $0) }.joined()
      try runtime.repository.quarantine(
        quarantineID: "activation-\(requestDigest.prefix(32))",
        packageDigest: packageDigest, reasonCode: "plugin.activation-health-failed",
        detailDigest: "sha256:\(detailDigest)", actorSubjectID: subjectID,
        timestamp: timestamp)
      throw error
    }
  }

  private static func bodyFields(
    _ body: ControlPlaneJSONValue?
  ) throws -> [String: ControlPlaneJSONValue] {
    if body == nil { return [:] }
    guard case .object(let fields) = body else { throw PluginControlError.invalidRequest }
    return fields
  }

  private static func requireExactKeys(
    _ fields: [String: ControlPlaneJSONValue], allowed: Set<String>
  ) throws {
    guard Set(fields.keys).isSubset(of: allowed) else {
      throw PluginControlError.invalidRequest
    }
  }

  private static func decodeField<T: Decodable>(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> T {
    guard let field = fields[name] else { throw PluginControlError.invalidRequest }
    return try JSONDecoder().decode(
      T.self, from: ControlPlaneCanonicalJSON.encode(field))
  }

  private static func optionalString(
    _ name: String, from fields: [String: ControlPlaneJSONValue], maximumBytes: Int = 128
  ) throws -> String? {
    guard let field = fields[name] else { return nil }
    guard case .string(let value) = field, !value.isEmpty,
      value.utf8.count <= maximumBytes,
      value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
    else { throw PluginControlError.invalidRequest }
    return value
  }

  private static func requiredString(
    _ name: String, from fields: [String: ControlPlaneJSONValue], maximumBytes: Int = 128
  ) throws -> String {
    guard let value = try optionalString(name, from: fields, maximumBytes: maximumBytes) else {
      throw PluginControlError.invalidRequest
    }
    return value
  }

  private static func optionalDigest(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> String? {
    guard let value = try optionalString(name, from: fields) else { return nil }
    guard value.range(
      of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
    else { throw PluginControlError.invalidRequest }
    return value
  }

  private static func requiredDigest(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> String {
    guard let value = try optionalDigest(name, from: fields) else {
      throw PluginControlError.invalidRequest
    }
    return value
  }

  private static func optionalInt(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Int? {
    guard let field = fields[name] else { return nil }
    guard case .integer(let value) = field, value >= 1, value <= Int64(Int.max) else {
      throw PluginControlError.invalidRequest
    }
    return Int(value)
  }

  private static func requiredInt(
    _ name: String, from fields: [String: ControlPlaneJSONValue]
  ) throws -> Int {
    guard let value = try optionalInt(name, from: fields) else {
      throw PluginControlError.invalidRequest
    }
    return value
  }

  private static func value<T: Encodable>(_ value: T) throws -> ControlPlaneJSONValue {
    try JSONDecoder().decode(
      ControlPlaneJSONValue.self, from: ControlPlaneCanonicalJSON.encode(value))
  }

  private static func failure(
    requestID: String, reason: ControlReasonCode, code: String, message: String
  ) -> ControlResponseEnvelope {
    ControlResponseEnvelope(
      requestID: requestID, status: .rejected, reasonCode: reason,
      error: SanitizedError(code: code, message: message))
  }
}

private struct PluginStatusResult: Encodable {
  let packages: [PluginPackageRecord]
  let activation: PluginActivationRecord?
}

private struct PluginDiscoveryResult: Encodable {
  let manifest: PluginPackageManifest
  let packageDigest: String
}

private enum PluginControlError: Error {
  case invalidRequest
  case idempotencyRequired
  case notFound
  case lifecycleConflict
  case materializedCleanupFailed
}
