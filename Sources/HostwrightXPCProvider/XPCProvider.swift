import Foundation
import HostwrightControlPlane
import Security
@preconcurrency import XPC

public enum XPCProviderError: Error, Equatable, Sendable {
  case invalidMessage
  case authenticationFailed
  case serviceUnavailable
  case timedOut
  case cancelled
  case revoked
  case invalidResponse
  case identityUnavailable

  public var reasonCode: String {
    switch self {
    case .invalidMessage: "invalid-message"
    case .authenticationFailed: "authentication-failed"
    case .serviceUnavailable: "service-unavailable"
    case .timedOut: "timed-out"
    case .cancelled: "cancelled"
    case .revoked: "revoked"
    case .invalidResponse: "invalid-response"
    case .identityUnavailable: "identity-unavailable"
    }
  }
}

public enum XPCProviderPeerRequirements {
  public static let daemonSigningIdentifier = "hostwrightd"

  public static var service: String {
    "anchor apple generic and certificate leaf[subject.OU] = \"\(XPCServiceContract.teamIdentifier)\" and identifier \"\(XPCServiceContract.serviceIdentifier)\" and entitlement[\"com.apple.security.app-sandbox\"]"
  }

  public static var daemon: String {
    "anchor apple generic and certificate leaf[subject.OU] = \"\(XPCServiceContract.teamIdentifier)\" and identifier \"\(daemonSigningIdentifier)\""
  }
}

public enum XPCProviderMessageCodec {
  private static let protocolKey = "protocolVersion"
  private static let kindKey = "kind"
  private static let requestIDKey = "requestID"
  private static let operationKey = "operation"
  private static let timeoutKey = "timeoutMilliseconds"
  private static let statusKey = "status"
  private static let teamKey = "teamIdentifier"
  private static let identifierKey = "signingIdentifier"
  private static let cdHashKey = "codeDirectoryHash"
  private static let entitlementProjectionKey = "entitlementProjection"
  private static let appSandboxEntitlementKey = "com.apple.security.app-sandbox"
  private static let errorCodeKey = "errorCode"
  private static let errorMessageKey = "errorMessage"

  public static func encode(_ request: XPCRequest) throws -> xpc_object_t {
    do { try request.validate() } catch { throw XPCProviderError.invalidMessage }
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(message, protocolKey, UInt64(request.protocolVersion))
    xpc_dictionary_set_string(message, kindKey, request.kind.rawValue)
    xpc_dictionary_set_string(message, requestIDKey, request.requestID)
    if let operation = request.operation {
      xpc_dictionary_set_string(message, operationKey, operation.rawValue)
    }
    if let timeout = request.timeoutMilliseconds {
      xpc_dictionary_set_uint64(message, timeoutKey, UInt64(timeout))
    }
    return message
  }

  public static func decodeRequest(_ message: xpc_object_t) throws -> XPCRequest {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
      throw XPCProviderError.invalidMessage
    }
    let keys = try exactKeys(message, maximum: 5)
    guard keys.contains(protocolKey), keys.contains(kindKey), keys.contains(requestIDKey),
      let version = uint(message, protocolKey), version <= UInt64(Int.max),
      let kindText = string(message, kindKey, maximumBytes: 16),
      let kind = XPCMessageKind(rawValue: kindText),
      let requestID = string(
        message, requestIDKey, maximumBytes: XPCRequest.maximumRequestIDBytes)
    else { throw XPCProviderError.invalidMessage }
    let request: XPCRequest
    switch kind {
    case .request:
      guard keys == [protocolKey, kindKey, requestIDKey, operationKey, timeoutKey],
        let operationText = string(message, operationKey, maximumBytes: 64),
        let operation = XPCOperation(rawValue: operationText),
        let timeout = uint(message, timeoutKey), timeout <= UInt64(Int.max)
      else { throw XPCProviderError.invalidMessage }
      request = XPCRequest(
        protocolVersion: Int(version), kind: kind, requestID: requestID,
        operation: operation, timeoutMilliseconds: Int(timeout))
    case .cancel:
      guard keys == [protocolKey, kindKey, requestIDKey] else {
        throw XPCProviderError.invalidMessage
      }
      request = XPCRequest(
        protocolVersion: Int(version), kind: kind, requestID: requestID,
        operation: nil, timeoutMilliseconds: nil)
    }
    do { try request.validate() } catch { throw XPCProviderError.invalidMessage }
    return request
  }

  public static func encode(_ response: XPCResponse, replyTo request: xpc_object_t? = nil) throws
    -> xpc_object_t
  {
    do { try response.validate() } catch { throw XPCProviderError.invalidResponse }
    let message = request.flatMap(xpc_dictionary_create_reply) ?? xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_uint64(message, protocolKey, UInt64(response.protocolVersion))
    xpc_dictionary_set_string(message, requestIDKey, response.requestID)
    xpc_dictionary_set_string(message, statusKey, response.status.rawValue)
    switch response.status {
    case .completed:
      guard let proof = response.proof else { throw XPCProviderError.invalidResponse }
      xpc_dictionary_set_string(message, teamKey, proof.teamIdentifier)
      xpc_dictionary_set_string(message, identifierKey, proof.signingIdentifier)
      xpc_dictionary_set_string(message, cdHashKey, proof.codeDirectoryHash)
      let projection = xpc_dictionary_create(nil, nil, 0)
      xpc_dictionary_set_bool(projection, appSandboxEntitlementKey, true)
      xpc_dictionary_set_value(message, entitlementProjectionKey, projection)
    case .cancelled: break
    case .error:
      guard let error = response.error else { throw XPCProviderError.invalidResponse }
      xpc_dictionary_set_string(message, errorCodeKey, error.code)
      xpc_dictionary_set_string(message, errorMessageKey, error.message)
    }
    return message
  }

  public static func decodeResponse(_ message: xpc_object_t) throws -> XPCResponse {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
      throw XPCProviderError.invalidResponse
    }
    let keys = try exactKeys(message, maximum: 7)
    guard keys.contains(protocolKey), keys.contains(requestIDKey), keys.contains(statusKey),
      let version = uint(message, protocolKey), version <= UInt64(Int.max),
      let requestID = string(
        message, requestIDKey, maximumBytes: XPCRequest.maximumRequestIDBytes),
      let statusText = string(message, statusKey, maximumBytes: 16),
      let status = XPCResponseStatus(rawValue: statusText)
    else { throw XPCProviderError.invalidResponse }
    let response: XPCResponse
    switch status {
    case .completed:
      guard keys == [
        protocolKey, requestIDKey, statusKey, teamKey, identifierKey, cdHashKey,
        entitlementProjectionKey,
      ],
        let team = string(message, teamKey, maximumBytes: 32),
        let identifier = string(message, identifierKey, maximumBytes: 128),
        let cdHash = string(message, cdHashKey, maximumBytes: 64),
        let projection = xpc_dictionary_get_value(message, entitlementProjectionKey),
        xpc_get_type(projection) == XPC_TYPE_DICTIONARY,
        try exactKeys(projection, maximum: 1) == [appSandboxEntitlementKey],
        bool(projection, appSandboxEntitlementKey) == true
      else { throw XPCProviderError.invalidResponse }
      response = XPCResponse(
        protocolVersion: Int(version), requestID: requestID, status: status,
        proof: CodeIdentityProof(
          teamIdentifier: team, signingIdentifier: identifier, codeDirectoryHash: cdHash))
    case .cancelled:
      guard keys == [protocolKey, requestIDKey, statusKey] else {
        throw XPCProviderError.invalidResponse
      }
      response = XPCResponse(protocolVersion: Int(version), requestID: requestID, status: status)
    case .error:
      guard keys == [protocolKey, requestIDKey, statusKey, errorCodeKey, errorMessageKey],
        let code = string(message, errorCodeKey, maximumBytes: 128),
        let text = string(message, errorMessageKey, maximumBytes: 1_024)
      else { throw XPCProviderError.invalidResponse }
      response = XPCResponse(
        protocolVersion: Int(version), requestID: requestID, status: status,
        error: SanitizedError(code: code, message: text))
    }
    do { try response.validate() } catch { throw XPCProviderError.invalidResponse }
    return response
  }

  private static func exactKeys(_ message: xpc_object_t, maximum: Int) throws -> Set<String> {
    var result = Set<String>()
    var valid = true
    xpc_dictionary_apply(message) { key, _ in
      let length = strnlen(key, 257)
      guard length > 0, length <= 256, result.count < maximum else {
        valid = false
        return false
      }
      result.insert(String(cString: key))
      return true
    }
    guard valid, !result.isEmpty else { throw XPCProviderError.invalidMessage }
    return result
  }

  private static func string(
    _ message: xpc_object_t, _ key: String, maximumBytes: Int
  ) -> String? {
    guard let value = xpc_dictionary_get_value(message, key),
      xpc_get_type(value) == XPC_TYPE_STRING,
      xpc_string_get_length(value) <= maximumBytes,
      let pointer = xpc_string_get_string_ptr(value)
    else { return nil }
    return String(cString: pointer)
  }

  private static func uint(_ message: xpc_object_t, _ key: String) -> UInt64? {
    guard let value = xpc_dictionary_get_value(message, key),
      xpc_get_type(value) == XPC_TYPE_UINT64
    else { return nil }
    return xpc_uint64_get_value(value)
  }

  private static func bool(_ message: xpc_object_t, _ key: String) -> Bool? {
    guard let value = xpc_dictionary_get_value(message, key),
      xpc_get_type(value) == XPC_TYPE_BOOL
    else { return nil }
    return xpc_bool_get_value(value)
  }
}

private final class PendingXPCReply: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<XPCResponse, Error>?
  private var result: Result<XPCResponse, Error>?

  func install(_ continuation: CheckedContinuation<XPCResponse, Error>) {
    let ready: Result<XPCResponse, Error>? = lock.withLock {
      if let result { return result }
      self.continuation = continuation
      return nil
    }
    if let ready { continuation.resume(with: ready) }
  }

  func resolve(_ result: Result<XPCResponse, Error>) {
    let continuation: CheckedContinuation<XPCResponse, Error>? = lock.withLock {
      guard self.result == nil else { return nil }
      self.result = result
      defer { self.continuation = nil }
      return self.continuation
    }
    continuation?.resume(with: result)
  }
}

public final class XPCProviderClient: @unchecked Sendable {
  private struct Active {
    let connection: xpc_connection_t
    let pending: PendingXPCReply
  }
  private let serviceName: String
  private let queue = DispatchQueue(label: "dev.hostwright.xpc-provider.client")
  private let lock = NSLock()
  private var active: [String: Active] = [:]
  private var revoked = false

  public init(serviceName: String = XPCServiceContract.serviceIdentifier) throws {
    guard !serviceName.isEmpty, serviceName.utf8.count <= 255,
      serviceName.unicodeScalars.allSatisfy({
        (48...57).contains($0.value) || (65...90).contains($0.value)
          || (97...122).contains($0.value) || "-_.".unicodeScalars.contains($0)
      })
    else { throw XPCProviderError.invalidMessage }
    self.serviceName = serviceName
  }

  public func execute(_ request: XPCRequest) async throws -> XPCResponse {
    let message = try XPCProviderMessageCodec.encode(request)
    let connection = xpc_connection_create_mach_service(serviceName, queue, 0)
    guard xpc_connection_set_peer_code_signing_requirement(
      connection, XPCProviderPeerRequirements.service) == 0
    else {
      xpc_connection_set_event_handler(connection) { _ in }
      xpc_connection_activate(connection)
      xpc_connection_cancel(connection)
      throw XPCProviderError.authenticationFailed
    }
    let pending = PendingXPCReply()
    let accepted = lock.withLock { () -> Bool in
      guard !revoked, active[request.requestID] == nil else { return false }
      active[request.requestID] = Active(connection: connection, pending: pending)
      return true
    }
    guard accepted else {
      xpc_connection_set_event_handler(connection) { _ in }
      xpc_connection_activate(connection)
      xpc_connection_cancel(connection)
      throw revoked ? XPCProviderError.revoked : XPCProviderError.invalidMessage
    }

    xpc_connection_set_event_handler(connection) { [weak self] event in
      guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
      let error: XPCProviderError = event === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT
        ? .authenticationFailed : .serviceUnavailable
      self?.complete(request.requestID, .failure(error))
    }
    xpc_connection_activate(connection)
    xpc_connection_send_message_with_reply(connection, message, queue) { [weak self] reply in
      guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
        let error: XPCProviderError = reply === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT
          ? .authenticationFailed : .serviceUnavailable
        self?.complete(request.requestID, .failure(error))
        return
      }
      do {
        let liveProof: CodeIdentityProof
        do {
          liveProof = try XPCProviderCodeIdentity.peer(connection)
        } catch {
          throw XPCProviderError.authenticationFailed
        }
        let response = try XPCProviderMessageCodec.decodeResponse(reply)
        guard response.requestID == request.requestID else {
          throw XPCProviderError.invalidResponse
        }
        if response.status == .completed, response.proof != liveProof {
          throw XPCProviderError.authenticationFailed
        }
        self?.complete(request.requestID, .success(response))
      } catch let error as XPCProviderError {
        self?.complete(request.requestID, .failure(error))
      } catch {
        self?.complete(request.requestID, .failure(XPCProviderError.invalidResponse))
      }
    }
    let timeout = UInt64(request.timeoutMilliseconds ?? 5_000)
    Task.detached { [weak self] in
      try? await Task.sleep(nanoseconds: timeout * 1_000_000)
      self?.cancel(request.requestID, reason: .timedOut, sendMessage: true)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { pending.install($0) }
    } onCancel: {
      self.cancel(request.requestID, reason: .cancelled, sendMessage: true)
    }
  }

  public func revoke() {
    let entries: [Active] = lock.withLock {
      revoked = true
      let values = Array(active.values)
      active.removeAll()
      return values
    }
    for entry in entries {
      xpc_connection_cancel(entry.connection)
      entry.pending.resolve(.failure(XPCProviderError.revoked))
    }
  }

  private func cancel(
    _ requestID: String, reason: XPCProviderError, sendMessage: Bool
  ) {
    let entry = lock.withLock { active.removeValue(forKey: requestID) }
    guard let entry else { return }
    if sendMessage, let cancel = try? XPCProviderMessageCodec.encode(XPCRequest(
      kind: .cancel, requestID: requestID, operation: nil, timeoutMilliseconds: nil)) {
      xpc_connection_send_message(entry.connection, cancel)
    }
    xpc_connection_cancel(entry.connection)
    entry.pending.resolve(.failure(reason))
  }

  private func complete(_ requestID: String, _ result: Result<XPCResponse, Error>) {
    let entry = lock.withLock { active.removeValue(forKey: requestID) }
    guard let entry else { return }
    xpc_connection_cancel(entry.connection)
    entry.pending.resolve(result)
  }
}

public enum XPCProviderCodeIdentity {
  private static let revocationFlag = UInt32(1) << 30

  public static func current() throws -> CodeIdentityProof {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
      throw XPCProviderError.identityUnavailable
    }
    return try inspect(code)
  }

  public static func peer(_ connection: xpc_connection_t) throws -> CodeIdentityProof {
    let pid = xpc_connection_get_pid(connection)
    guard pid > 0 else { throw XPCProviderError.identityUnavailable }
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code
    else { throw XPCProviderError.identityUnavailable }
    return try inspect(code)
  }

  public static func file(_ url: URL) throws -> CodeIdentityProof {
    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
      throw XPCProviderError.identityUnavailable
    }
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode,
      SecStaticCodeCheckValidity(
        staticCode, SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag), nil)
        == errSecSuccess
    else { throw XPCProviderError.identityUnavailable }
    return try inspect(staticCode)
  }

  private static func inspect(_ code: SecCode) throws -> CodeIdentityProof {
    guard SecCodeCheckValidity(
      code, SecCSFlags(rawValue: kSecCSStrictValidate | revocationFlag), nil) == errSecSuccess
    else { throw XPCProviderError.identityUnavailable }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
      throw XPCProviderError.identityUnavailable
    }
    return try inspect(staticCode)
  }

  private static func inspect(_ staticCode: SecStaticCode) throws -> CodeIdentityProof {
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let values = information as? [String: Any],
      let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
      let identifier = values[kSecCodeInfoIdentifier as String] as? String,
      let unique = values[kSecCodeInfoUnique as String] as? Data,
      let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      entitlements.count == 1,
      entitlements["com.apple.security.app-sandbox"] as? Bool == true
    else { throw XPCProviderError.identityUnavailable }
    let proof = CodeIdentityProof(
      teamIdentifier: team, signingIdentifier: identifier,
      codeDirectoryHash: unique.map { String(format: "%02x", $0) }.joined(),
      entitlementProjection: ["com.apple.security.app-sandbox": .bool(true)])
    do { try proof.validate() } catch { throw XPCProviderError.identityUnavailable }
    return proof
  }
}

public enum XPCProviderServiceMode: String, Sendable {
  case normal, hang, crash, malformed, oversized
}

public enum XPCProviderServiceRuntime {
  public static func run(
    serviceName: String = XPCServiceContract.serviceIdentifier,
    mode: XPCProviderServiceMode = .normal
  ) -> Never {
    let listenerQueue = DispatchQueue(label: "dev.hostwright.xpc-provider.listener")
    let listener = xpc_connection_create_mach_service(
      serviceName, listenerQueue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { event in
      guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
      let peer = unsafeBitCast(event, to: xpc_connection_t.self)
      guard xpc_connection_set_peer_code_signing_requirement(
        peer, XPCProviderPeerRequirements.daemon) == 0
      else {
        xpc_connection_set_event_handler(peer) { _ in }
        xpc_connection_activate(peer)
        xpc_connection_cancel(peer)
        return
      }
      let session = XPCProviderPeerSession(connection: peer, mode: mode)
      session.activate()
    }
    xpc_connection_activate(listener)
    dispatchMain()
  }
}

private final class XPCProviderPeerSession: @unchecked Sendable {
  private let connection: xpc_connection_t
  private let mode: XPCProviderServiceMode
  private let executionQueue = DispatchQueue(
    label: "dev.hostwright.xpc-provider.execution", qos: .userInitiated,
    attributes: .concurrent)
  private let lock = NSLock()
  private var active: [String: DispatchWorkItem] = [:]

  init(connection: xpc_connection_t, mode: XPCProviderServiceMode) {
    self.connection = connection
    self.mode = mode
  }

  func activate() {
    xpc_connection_set_event_handler(connection) { [self] event in
      if xpc_get_type(event) == XPC_TYPE_ERROR {
        cancelAll()
        return
      }
      guard let request = try? XPCProviderMessageCodec.decodeRequest(event) else {
        sendError(requestID: "invalid", code: "invalid-message", replyTo: event)
        return
      }
      switch request.kind {
      case .cancel: cancel(request.requestID)
      case .request: execute(request, event: event)
      }
    }
    xpc_connection_activate(connection)
  }

  private func execute(_ request: XPCRequest, event: xpc_object_t) {
    var work: DispatchWorkItem!
    work = DispatchWorkItem { [self] in
      switch mode {
      case .crash: _exit(70)
      case .hang:
        while !work.isCancelled { usleep(10_000) }
      case .malformed:
        let reply = xpc_dictionary_create_reply(event) ?? xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, "protocolVersion", 1)
        xpc_dictionary_set_string(reply, "requestID", request.requestID)
        xpc_dictionary_set_string(reply, "status", "completed")
        xpc_dictionary_set_bool(reply, "unexpected", true)
        xpc_connection_send_message(connection, reply)
      case .oversized:
        let reply = xpc_dictionary_create_reply(event) ?? xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, "protocolVersion", 1)
        xpc_dictionary_set_string(reply, "requestID", request.requestID)
        xpc_dictionary_set_string(reply, "status", "completed")
        let bytes = [UInt8](repeating: 0, count: XPCRequest.maximumMessageBytes + 1)
        bytes.withUnsafeBytes {
          xpc_dictionary_set_data(reply, "unexpected", $0.baseAddress, $0.count)
        }
        xpc_connection_send_message(connection, reply)
      case .normal:
        if work.isCancelled { break }
        do {
          let proof = try XPCProviderCodeIdentity.current()
          if work.isCancelled { break }
          let response = XPCResponse(
            requestID: request.requestID, status: .completed, proof: proof)
          xpc_connection_send_message(
            connection, try XPCProviderMessageCodec.encode(response, replyTo: event))
        } catch {
          sendError(requestID: request.requestID, code: "identity-unavailable", replyTo: event)
        }
      }
      if work.isCancelled {
        let response = XPCResponse(requestID: request.requestID, status: .cancelled)
        if let reply = try? XPCProviderMessageCodec.encode(response, replyTo: event) {
          xpc_connection_send_message(connection, reply)
        }
      }
      _ = lock.withLock { active.removeValue(forKey: request.requestID) }
    }
    let inserted = lock.withLock { () -> Bool in
      guard active[request.requestID] == nil else { return false }
      active[request.requestID] = work
      return true
    }
    guard inserted else {
      sendError(requestID: request.requestID, code: "duplicate-request", replyTo: event)
      return
    }
    executionQueue.async(execute: work)
  }

  private func cancel(_ requestID: String) {
    lock.withLock { active[requestID] }?.cancel()
  }

  private func cancelAll() {
    let work = lock.withLock {
      let values = Array(active.values)
      active.removeAll()
      return values
    }
    work.forEach { $0.cancel() }
  }

  private func sendError(requestID: String, code: String, replyTo event: xpc_object_t) {
    let response = XPCResponse(
      requestID: XPCRequest.validRequestID(requestID) ? requestID : "invalid",
      status: .error, error: SanitizedError(code: code, message: "XPC request rejected."))
    if let reply = try? XPCProviderMessageCodec.encode(response, replyTo: event) {
      xpc_connection_send_message(connection, reply)
    }
  }
}
