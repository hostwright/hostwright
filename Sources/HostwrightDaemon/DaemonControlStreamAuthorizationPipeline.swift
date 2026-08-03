import CryptoKit
import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity
import HostwrightControlTransport
import HostwrightPolicy
import HostwrightState

final class DaemonControlStreamAuthorizationPipeline: @unchecked Sendable {
  private let store: SQLiteStateStore
  private let rbacAuthorizer: RBACAuthorizationEngine
  private let admissionEngine: AdmissionPolicyEngine
  private let requestRepository: ControlRequestRepository
  private let auditRecorder: any ControlSecurityAuditRecording
  private let validateStreamRequest: @Sendable (ControlStreamOpenRequest) throws -> Void

  init(
    store: SQLiteStateStore,
    rbacAuthorizer: RBACAuthorizationEngine,
    admissionEngine: AdmissionPolicyEngine,
    requestRepository: ControlRequestRepository,
    auditRecorder: any ControlSecurityAuditRecording,
    validateStreamRequest: @escaping @Sendable (ControlStreamOpenRequest) throws -> Void
  ) {
    self.store = store
    self.rbacAuthorizer = rbacAuthorizer
    self.admissionEngine = admissionEngine
    self.requestRepository = requestRepository
    self.auditRecorder = auditRecorder
    self.validateStreamRequest = validateStreamRequest
  }

  func authorize(
    peer: AuthenticatedControlPeer,
    streamID _: String,
    request: ControlStreamOpenRequest,
    at: Date
  ) throws -> ControlStreamAuthorization {
    let decision = try reauthorize(peer: peer, request: request, at: at)
    let decisionDigest = try digest(decision)
    let auditID = request.requestID ?? "stream-open:\(UUID().uuidString.lowercased())"
    var auditHealthDegraded = false
    do {
      _ = try auditRecorder.record(ControlSecurityAuditEvent(
        subjectID: peer.binding.subject.identifier,
        requestID: auditID,
        target: request.target ?? "stream:\(request.source.rawValue)",
        action: .authorization,
        outcome: decision.effect.rawValue,
        reasonCode: decision.reasonCode,
        payloadDigest: "sha256:\(decisionDigest)",
        deduplicationKey: "\(auditID):authorization"
      ))
    } catch {
      guard !Self.requiresHealthyAudit(request.source) else {
        throw ControlStreamAuthorizationError.auditUnavailable
      }
      auditHealthDegraded = true
    }
    guard decision.effect == .allow else {
      return ControlStreamAuthorization(
        decision: decision,
        auditHealthDegraded: auditHealthDegraded
      )
    }

    guard Self.requiresAdmission(request.source) else {
      do { try validateStreamRequest(request) }
      catch { throw ControlStreamAuthorizationError.invalidRequest }
      return ControlStreamAuthorization(
        decision: decision,
        auditHealthDegraded: auditHealthDegraded
      )
    }

    guard let requestID = request.requestID, let idempotencyKey = request.idempotencyKey else {
      throw ControlStreamAuthorizationError.persistenceFailed
    }
    let operationRef = "stream:" + SHA256.hash(
      data: Data("\(peer.binding.subject.identifier):\(requestID)".utf8)
    ).prefix(16).map { String(format: "%02x", $0) }.joined()
    let synthetic = ControlRequestEnvelope(
      requestID: requestID,
      operation: "stream.\(request.source.rawValue)",
      timeoutMilliseconds: 300_000,
      idempotencyKey: idempotencyKey,
      body: .object([
        "resourceUUID": request.target.map(ControlPlaneJSONValue.string) ?? .null,
        "streamSource": .string(request.source.rawValue),
        "streamFilter": request.filter ?? .null,
      ])
    )
    let evaluated: AdmissionPipelineEvaluation
    do {
      evaluated = try admissionEngine.evaluate(
        subjectID: peer.binding.subject.identifier,
        request: synthetic,
        at: at
      )
    } catch {
      _ = try recordRequiredAudit(ControlSecurityAuditEvent(
        subjectID: peer.binding.subject.identifier,
        requestID: requestID,
        target: request.target ?? "stream:\(request.source.rawValue)",
        action: .admission,
        outcome: "error",
        reasonCode: "admission.policy-failed",
        payloadDigest: "sha256:" + Self.digest(Data("admission.policy-failed".utf8)),
        deduplicationKey: "\(requestID):admission-error"
      ))
      throw ControlStreamAuthorizationError.admissionDenied
    }
    let admissionDigest = try digest(evaluated.decisions)
    _ = try recordRequiredAudit(ControlSecurityAuditEvent(
      subjectID: peer.binding.subject.identifier,
      requestID: requestID,
      target: request.target ?? "stream:\(request.source.rawValue)",
      action: .admission,
      outcome: evaluated.allowed ? "allowed" : "denied",
      reasonCode: evaluated.reasonCode,
      planRef: "sha256:\(evaluated.planHash)",
      approvalRef: evaluated.approvalIdentity,
      operationRef: operationRef,
      payloadDigest: "sha256:\(admissionDigest)",
      deduplicationKey: "\(requestID):admission:\(admissionDigest)"
    ))
    guard evaluated.allowed, !evaluated.dryRun,
      evaluated.effectiveRequest.apiVersion == synthetic.apiVersion,
      evaluated.effectiveRequest.protocolRevision == synthetic.protocolRevision,
      evaluated.effectiveRequest.requestID == synthetic.requestID,
      evaluated.effectiveRequest.operation == synthetic.operation,
      evaluated.effectiveRequest.timeoutMilliseconds == synthetic.timeoutMilliseconds,
      evaluated.effectiveRequest.idempotencyKey == synthetic.idempotencyKey,
      case .object(let effectiveBody)? = evaluated.effectiveRequest.body,
      Set(effectiveBody.keys) == ["resourceUUID", "streamSource", "streamFilter"],
      case .string(let effectiveSource)? = effectiveBody["streamSource"],
      effectiveSource == request.source.rawValue
    else { throw ControlStreamAuthorizationError.admissionDenied }

    let effectiveTarget: String?
    switch effectiveBody["resourceUUID"] {
    case .string(let value)?: effectiveTarget = value
    case .null?: effectiveTarget = nil
    default: throw ControlStreamAuthorizationError.admissionDenied
    }
    let effectiveFilter: ControlPlaneJSONValue?
    switch effectiveBody["streamFilter"] {
    case .null?: effectiveFilter = nil
    case let value?: effectiveFilter = value
    case nil: throw ControlStreamAuthorizationError.admissionDenied
    }
    let effectiveStreamRequest = ControlStreamOpenRequest(
      source: request.source,
      target: effectiveTarget,
      filter: effectiveFilter,
      heartbeatMilliseconds: request.heartbeatMilliseconds,
      requestID: requestID,
      idempotencyKey: idempotencyKey
    )
    try effectiveStreamRequest.validate()
    do { try validateStreamRequest(effectiveStreamRequest) }
    catch { throw ControlStreamAuthorizationError.invalidRequest }

    let effectiveDecision = try reauthorize(
      peer: peer,
      request: effectiveStreamRequest,
      at: at
    )
    let effectiveDecisionDigest = try digest(effectiveDecision)
    _ = try recordRequiredAudit(ControlSecurityAuditEvent(
      subjectID: peer.binding.subject.identifier,
      requestID: requestID,
      target: effectiveTarget ?? "stream:\(request.source.rawValue)",
      action: .authorization,
      outcome: effectiveDecision.effect.rawValue,
      reasonCode: effectiveDecision.reasonCode,
      operationRef: operationRef,
      payloadDigest: "sha256:\(effectiveDecisionDigest)",
      deduplicationKey: "\(requestID):effective-authorization:\(effectiveDecisionDigest)"
    ))
    guard effectiveDecision.effect == .allow else {
      throw ControlStreamAuthorizationError.admissionDenied
    }

    let requestBinding: ControlPlaneJSONValue = .object([
      "originalStreamRequest": try ControlStreamFrameContract.value(request),
      "effectiveRequest": try ControlStreamFrameContract.value(evaluated.effectiveRequest),
      "evaluationDigestSHA256": .string(evaluated.evaluationDigestSHA256),
      "planHash": .string(evaluated.planHash),
      "exceptionIDs": .array(evaluated.exceptionIDs.map(ControlPlaneJSONValue.string)),
      "effectiveAuthorizationDigestSHA256": .string(effectiveDecisionDigest),
    ])
    let requestDigest = Self.digest(try ControlPlaneCanonicalJSON.encode(requestBinding))
    let timestamp = ISO8601DateFormatter().string(from: at)
    guard let effectiveTarget = effectiveStreamRequest.target,
      case .object(let effectiveFilterFields)? = effectiveStreamRequest.filter,
      case .string(let effectiveServiceName)? = effectiveFilterFields["serviceName"]
    else { throw ControlStreamAuthorizationError.admissionDenied }
    let operationOwnership = try matchingOwnership(
      target: effectiveTarget,
      serviceName: effectiveServiceName
    )
    guard operationOwnership.count == 1 else {
      throw ControlStreamAuthorizationError.admissionDenied
    }
    if let existing = try requestRepository.load(
      subjectID: peer.binding.subject.identifier,
      idempotencyKey: idempotencyKey
    ), existing.requestID != requestID || existing.requestDigestSHA256 != requestDigest {
      throw ControlStreamAuthorizationError.idempotencyConflict
    }
    let startDisposition: ControlStreamOperationStartDisposition
    do {
      startDisposition = try requestRepository.beginStreamOperation(ControlRequestSubmission(
        request: ControlRequestRecord(
          requestID: requestID,
          subjectID: peer.binding.subject.identifier,
          idempotencyKey: idempotencyKey,
          requestDigestSHA256: requestDigest,
          status: .accepted,
          operationReference: operationRef,
          createdAt: timestamp,
          updatedAt: timestamp
        ),
        idempotencyExpiresAt: ISO8601DateFormatter().string(
          from: at.addingTimeInterval(24 * 60 * 60))
      ), operationReference: operationRef,
      plannedActionType: evaluated.effectiveRequest.operation,
      projectID: operationOwnership[0].projectID,
      serviceName: effectiveServiceName)
    } catch ControlRequestRepositoryError.idempotencyConflict {
      throw ControlStreamAuthorizationError.idempotencyConflict
    } catch let error as ControlStreamAuthorizationError {
      throw error
    } catch {
      throw ControlStreamAuthorizationError.persistenceFailed
    }
    _ = try recordRequiredAudit(ControlSecurityAuditEvent(
      subjectID: peer.binding.subject.identifier,
      requestID: requestID,
      target: effectiveTarget,
      action: .request,
      outcome: "accepted",
      reasonCode: "stream.accepted",
      operationRef: operationRef,
      payloadDigest: "sha256:\(requestDigest)",
      deduplicationKey: "\(requestID):accepted:\(requestDigest)"
    ))
    return ControlStreamAuthorization(
      decision: effectiveDecision,
      operationReference: operationRef,
      shouldStartProducer: startDisposition.shouldStart,
      effectiveRequest: effectiveStreamRequest
    )
  }

  func reauthorize(
    peer: AuthenticatedControlPeer,
    request: ControlStreamOpenRequest,
    at: Date
  ) throws -> RBACDecision {
    try rbacAuthorizer.authorizeStream(
      subject: peer.binding.subject,
      request: request,
      projectIdentifier: try authoritativeProject(request),
      at: at
    )
  }

  private func authoritativeProject(_ request: ControlStreamOpenRequest) throws -> String? {
    guard request.source == .logs || request.source == .attach || request.source == .exec,
      let target = request.target,
      case .object(let fields)? = request.filter,
      case .string(let serviceName)? = fields["serviceName"]
    else { return nil }
    let matching = try matchingOwnership(target: target, serviceName: serviceName)
    guard matching.count <= 1 else {
      throw ControlStreamAuthorizationError.invalidRequest
    }
    return matching.first?.projectResourceUUID
  }

  private func matchingOwnership(target: String, serviceName: String) throws -> [OwnershipRecord] {
    try store.ownership.loadAll().filter {
      $0.resourceType == "container"
        && $0.resourceUUID == target
        && $0.serviceName == serviceName
    }
  }

  private func recordRequiredAudit(_ event: ControlSecurityAuditEvent) throws -> AuditRecord {
    do { return try auditRecorder.record(event) }
    catch { throw ControlStreamAuthorizationError.auditUnavailable }
  }

  private func digest<T: Encodable>(_ value: T) throws -> String {
    Self.digest(try ControlPlaneCanonicalJSON.encode(value))
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func requiresAdmission(_ source: ControlStreamSource) -> Bool {
    source == .exec || source == .attach
  }

  private static func requiresHealthyAudit(_ source: ControlStreamSource) -> Bool {
    requiresAdmission(source)
  }
}
