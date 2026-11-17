import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightCore

final class ControlUnaryDispatcher: @unchecked Sendable {
  typealias Processor = @Sendable (
    ControlRequestEnvelope, OwnedInputDescriptor?
  ) throws -> (response: ControlResponseEnvelope, deadline: ControlTransportDeadline)

  private let descriptor: Int32
  private let context: ControlStreamConnectionContext
  private let processor: Processor
  private let queue = DispatchQueue(
    label: "dev.hostwright.control.unary",
    attributes: .concurrent
  )
  private let group = DispatchGroup()
  private let lock = NSLock()
  private let cancellation = HostwrightCancellationToken()
  private var inputCancellations: [UUID: HostwrightCancellationToken] = [:]
  private var inputDisconnected = false
  private var outstanding = 0
  private var failed = false

  init(
    descriptor: Int32,
    context: ControlStreamConnectionContext,
    processor: @escaping Processor
  ) {
    self.descriptor = descriptor
    self.context = context
    self.processor = processor
  }

  func submit(_ request: ControlRequestEnvelope, input: OwnedInputDescriptor? = nil) throws {
    let inputID = input == nil ? nil : UUID()
    let requestCancellation = input == nil ? cancellation : HostwrightCancellationToken()
    let admitted = lock.withLock { () -> Bool in
      guard !failed, !(input != nil && inputDisconnected),
        outstanding < ControlPlaneContract.maximumOutstandingUnary else {
        return false
      }
      outstanding += 1
      if let inputID { inputCancellations[inputID] = requestCancellation }
      return true
    }
    guard admitted else {
      input?.close()
      let deadline = try ControlTransportDeadline(
        timeoutMilliseconds: request.timeoutMilliseconds!
      )
      try context.writeResponse(
        ControlResponseEnvelope(
          requestID: request.requestID,
          status: .rejected,
          reasonCode: .concurrencyLimit,
          error: SanitizedError(
            code: "unaryConcurrencyLimit",
            message: "The connection has reached its unary request limit."
          )
        ),
        deadline: deadline
      )
      return
    }
    group.enter()
    queue.async { [self] in
      defer {
        input?.close()
        lock.withLock {
          outstanding -= 1
          if let inputID { inputCancellations.removeValue(forKey: inputID) }
        }
        group.leave()
      }
      do {
        let result = try HostwrightCancellationContext.$token.withValue(requestCancellation) {
          guard !requestCancellation.isCancelled else { throw CancellationError() }
          return try processor(request, input)
        }
        if disconnectedInput(inputID, cancellation: requestCancellation) { return }
        try context.writeResponse(result.response, deadline: result.deadline)
      } catch {
        if disconnectedInput(inputID, cancellation: requestCancellation) { return }
        failConnection()
      }
    }
  }

  func drain(timeoutMilliseconds: Int = 5_000) {
    if group.wait(timeout: .now() + .milliseconds(timeoutMilliseconds)) == .timedOut {
      failConnection()
    }
  }

  func cancel() { failConnection() }

  func cancelInputRequests() {
    let tokens = lock.withLock {
      inputDisconnected = true
      return Array(inputCancellations.values)
    }
    for token in tokens { token.cancel() }
  }

  private func disconnectedInput(_ inputID: UUID?, cancellation: HostwrightCancellationToken) -> Bool {
    inputID != nil && cancellation.isCancelled && lock.withLock { inputDisconnected }
  }

  private func failConnection() {
    let tokens = lock.withLock { () -> [HostwrightCancellationToken]? in
      if failed { return nil }
      failed = true
      return Array(inputCancellations.values)
    }
    if let tokens {
      cancellation.cancel()
      for token in tokens { token.cancel() }
      _ = shutdown(descriptor, SHUT_RDWR)
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
