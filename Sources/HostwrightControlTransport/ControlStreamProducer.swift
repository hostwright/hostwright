import Foundation
import HostwrightControlPlane
import HostwrightControlSecurity

public enum ControlStreamEmission: Equatable, Sendable {
  case data(cursor: String?, payload: ControlPlaneJSONValue)
  case heartbeat
  case gap(cursor: String?, payload: ControlStreamGap)
  case end(cursor: String?)
  case failure(SanitizedError)
}

public enum ControlStreamEmissionDisposition: Equatable, Sendable {
  case accepted
  case creditExhausted
  case terminated
}

public enum ControlStreamCancellationMode: Equatable, Sendable {
  case immediate
  case deferredUntilProducerTerminal
}

public enum ControlStreamAuthorizationError: Error, Equatable, Sendable {
  case admissionDenied
  case persistenceFailed
  case auditUnavailable
  case idempotencyConflict
  case invalidRequest
}

public struct ControlStreamProducerHandle: Sendable {
  private let creditHandler: @Sendable (Int) -> Void
  private let cancellationHandler: @Sendable () -> Void
  private let inputHandler:
    @Sendable (ControlPlaneJSONValue, @escaping @Sendable () -> Void) -> Bool
  private let finishInputHandler: @Sendable () -> Void
  public let cancellationMode: ControlStreamCancellationMode

  public init(
    onCredit: @escaping @Sendable (Int) -> Void = { _ in },
    onInput: @escaping @Sendable (
      ControlPlaneJSONValue, @escaping @Sendable () -> Void
    ) -> Bool = { _, _ in false },
    finishInput: @escaping @Sendable () -> Void = {},
    cancellationMode: ControlStreamCancellationMode = .immediate,
    cancel: @escaping @Sendable () -> Void
  ) {
    creditHandler = onCredit
    cancellationHandler = cancel
    inputHandler = onInput
    finishInputHandler = finishInput
    self.cancellationMode = cancellationMode
  }

  public func addCredit(_ credit: Int) { creditHandler(credit) }
  public func cancel() { cancellationHandler() }
  public func sendInput(
    _ payload: ControlPlaneJSONValue,
    onConsumed: @escaping @Sendable () -> Void
  ) -> Bool { inputHandler(payload, onConsumed) }
  public func finishInput() { finishInputHandler() }
}

public struct ControlStreamAuthorization: Sendable {
  public let decision: RBACDecision
  public let operationReference: String?
  public let shouldStartProducer: Bool
  public let effectiveRequest: ControlStreamOpenRequest?
  public let auditHealthDegraded: Bool
  public init(
    decision: RBACDecision,
    operationReference: String? = nil,
    shouldStartProducer: Bool = true,
    effectiveRequest: ControlStreamOpenRequest? = nil,
    auditHealthDegraded: Bool = false
  ) {
    self.decision = decision
    self.operationReference = operationReference
    self.shouldStartProducer = shouldStartProducer
    self.effectiveRequest = effectiveRequest
    self.auditHealthDegraded = auditHealthDegraded
  }
}

public typealias ControlStreamAuthorizer =
  @Sendable (
    AuthenticatedControlPeer,
    String,
    ControlStreamOpenRequest,
    Date
  ) throws -> ControlStreamAuthorization

public typealias ControlStreamOpener =
  @Sendable (
    AuthenticatedControlPeer,
    ControlStreamOpenRequest,
    String?,
    @escaping @Sendable (ControlStreamEmission) -> ControlStreamEmissionDisposition
  ) throws -> ControlStreamProducerHandle

public typealias ControlStreamReauthorizer =
  @Sendable (AuthenticatedControlPeer, ControlStreamOpenRequest, Date) throws -> RBACDecision

public typealias ControlStreamCursorValidator =
  @Sendable (AuthenticatedControlPeer, ControlStreamOpenRequest, String?) throws -> Void
